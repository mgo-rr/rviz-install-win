"""rosbag_play.py - `rosbag play` for the RViz MSI (launchers\\rosbag.cmd play ...).

Runs the normal `rosbag play`, which starts RoboStack's play.exe. Where
Windows refuses to start play.exe - Smart App Control blocks unsigned
programs it has no reputation for (WinError 4551) - it falls back to a
player written in Python on the bundled rosbag and rospy modules, which
Windows does allow. RVIZ_BAG_PLAYER=python forces the Python player.

The Python player publishes each message's original bytes (no decoding, so
point clouds and images stay cheap), keeps each topic's type and latching
from the bag (maps and /tf_static reach late subscribers such as RViz), and
publishes /clock while playing when --clock is given. It never reads ROS
time itself, so use_sim_time on this machine cannot stall it.
"""
import argparse
import heapq
import os
import sys
import time

# Windows refused to start the program: blocked by a code integrity policy
# (Smart App Control / App Control), or by a software restriction policy.
BLOCKED_WINERRORS = {4551, 1260}

PLAYER_OPTIONS = """Python player options (the ones play.exe has as well):
  --clock          publish the bag time on /clock (for use_sim_time)
  --hz HZ          /clock rate, default 100
  --pause          start paused; in a console: Space pauses/resumes, s steps
  -r, --rate F     play F times as fast
  -s, --start SEC  start SEC seconds into the bags
  -u, --duration SEC  play only SEC seconds
  -l, --loop       loop playback
  -k, --keep-alive keep publishing latched topics after the end
  -d, --delay SEC  wait SEC after advertising (default 2)
  -q, --quiet      no progress line
  --topics T...    play only these topics (then name the bags with --bags)"""


def parse_args(argv):
    p = argparse.ArgumentParser(prog="rosbag play (Python player)", add_help=False)
    p.add_argument("--clock", action="store_true")
    p.add_argument("--hz", type=float, default=100.0)
    p.add_argument("--pause", action="store_true")
    p.add_argument("-r", "--rate", type=float, default=1.0)
    p.add_argument("-s", "--start", type=float, default=0.0)
    p.add_argument("-u", "--duration", type=float, default=None)
    p.add_argument("-l", "--loop", action="store_true")
    p.add_argument("-k", "--keep-alive", action="store_true")
    p.add_argument("-d", "--delay", type=float, default=2.0)
    p.add_argument("-q", "--quiet", action="store_true")
    p.add_argument("--topics", nargs="+", default=[])
    p.add_argument("--bags", nargs="+", default=[])
    p.add_argument("bagfiles", nargs="*")
    args, unknown = p.parse_known_args(argv)
    if unknown:
        raise SystemExit("rosbag play (Python player): not supported here: %s\n%s"
                         % (" ".join(unknown), PLAYER_OPTIONS))
    args.bagfiles = args.bagfiles + args.bags
    if not args.bagfiles:
        raise SystemExit("rosbag play: no bag file given\n" + PLAYER_OPTIONS)
    if args.rate <= 0 or args.hz <= 0:
        raise SystemExit("rosbag play: --rate and --hz must be positive")
    return args


def header_flag(header, key):
    v = header.get(key)
    if isinstance(v, bytes):
        v = v.decode("utf-8", "replace")
    return v == "1"


class Keyboard(object):
    """Space toggles pause, s steps one message. Inactive without a console."""

    def __init__(self, paused):
        self.paused = paused
        self.step = False
        try:
            import msvcrt
            self._msvcrt = msvcrt if sys.stdin.isatty() else None
        except ImportError:
            self._msvcrt = None

    def poll(self):
        while self._msvcrt and self._msvcrt.kbhit():
            ch = self._msvcrt.getwch()
            if ch == " ":
                self.paused = not self.paused
            elif ch in ("s", "S") and self.paused:
                self.step = True


def merged_messages(bags, topics, start, end):
    """All messages of all bags in time order, as raw bytes."""
    streams = [b.read_messages(topics=topics or None, start_time=start, end_time=end, raw=True)
               for b in bags]
    return heapq.merge(*streams, key=lambda m: m.timestamp.to_sec())


def python_play(args):
    import genpy
    import rosbag
    import rospy
    from rosgraph_msgs.msg import Clock

    bags = [rosbag.Bag(f) for f in args.bagfiles]
    t0 = min(b.get_start_time() for b in bags)
    t_end = max(b.get_end_time() for b in bags)
    first = t0 + args.start
    last = t_end if args.duration is None else min(t_end, first + args.duration)
    if first > t_end:
        raise SystemExit("rosbag play: --start %.1f is past the end of the bags (%.1f s long)"
                         % (args.start, t_end - t0))

    rospy.init_node("play", anonymous=True, disable_signals=True)
    raw_classes, pubs = {}, {}
    for b in bags:
        for c in b._get_connections(args.topics or None):
            if c.topic in pubs:
                continue
            base = rosbag.bag._get_message_type(c)
            cls = raw_classes.get(c.md5sum)
            if cls is None:
                # Same type name, md5sum and definition as the original, so
                # subscribers accept it; serialize() writes the bag's bytes.
                cls = type("Raw_" + base.__name__, (base,),
                           {"__slots__": ["_raw"],
                            "serialize": lambda self, buff: buff.write(self._raw)})
                raw_classes[c.md5sum] = cls
            pubs[c.topic] = (rospy.Publisher(c.topic, cls, queue_size=100,
                                             latch=header_flag(c.header, "latching")), cls)
    clock_pub = rospy.Publisher("/clock", Clock, queue_size=10) if args.clock else None
    if not args.quiet:
        print("[ INFO] Python player: %d topics from %d bag(s), %.1f s of %.1f s"
              % (len(pubs), len(bags), last - first, t_end - t0))
    time.sleep(args.delay)   # let subscribers connect (XML-RPC can be slow)

    keys = Keyboard(args.pause)
    clock_period = 1.0 / args.hz
    status_period = 0.25

    def publish_clock(bag_time):
        if clock_pub:
            clock_pub.publish(Clock(clock=genpy.Time.from_sec(bag_time)))

    while True:
        wall0, bag0 = time.monotonic(), first
        next_clock = next_status = 0.0
        paused_at = first if keys.paused else None
        for m in merged_messages(bags, args.topics, genpy.Time.from_sec(first), genpy.Time.from_sec(last)):
            t = m.timestamp.to_sec()
            while True:
                keys.poll()
                now = time.monotonic()
                if keys.paused:
                    if paused_at is None:
                        paused_at = bag0 + (now - wall0) * args.rate
                    if keys.step:
                        keys.step = False
                        paused_at = t
                        break
                    sim = paused_at
                else:
                    if paused_at is not None:      # resume where we paused
                        wall0, bag0, paused_at = now, paused_at, None
                    sim = bag0 + (now - wall0) * args.rate
                    if sim >= t:
                        break
                if now >= next_clock:
                    publish_clock(min(sim, t))
                    next_clock = now + clock_period
                if not args.quiet and now >= next_status:
                    sys.stdout.write("\r [%s]  Bag Time: %13.6f   Duration: %.6f / %.6f      "
                                     % ("PAUSED " if keys.paused else "RUNNING", sim, sim - t0, t_end - t0))
                    sys.stdout.flush()
                    next_status = now + status_period
                time.sleep(min(clock_period, max(0.0, (t - sim) / args.rate), 0.01))
            if time.monotonic() >= next_clock:
                publish_clock(t)
                next_clock = time.monotonic() + clock_period
            pub, cls = pubs[m.topic]
            msg = cls()
            msg._raw = m.message[1]
            pub.publish(msg)
        if not args.loop:
            break
    if not args.quiet:
        print("\nDone.")
    if args.keep_alive:
        print("Keeping latched topics alive; Ctrl+C to stop.")
        while True:
            time.sleep(1)


def main(argv):
    if argv[:1] == ["play"]:
        argv = argv[1:]
    if os.environ.get("RVIZ_BAG_PLAYER", "").lower() != "python":
        import rosbag
        try:
            return rosbag.rosbagmain(["rosbag", "play"] + argv)
        except OSError as e:
            if getattr(e, "winerror", None) not in BLOCKED_WINERRORS:
                raise
            print("\n[rosbag] Windows blocked play.exe (%s). Using the bundled Python player instead."
                  % e.strerror, file=sys.stderr)
    args = parse_args(argv)
    try:
        python_play(args)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        if "rospy" in sys.modules:
            sys.modules["rospy"].signal_shutdown("playback finished")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
