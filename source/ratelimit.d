module mirror.ratelimit;

import std.container.rbtree;
import std.datetime;
import core.thread;

struct Parcel
{
    SysTime time;
    size_t size;

    int opCmp(ref const Parcel other) const
    {
        return time.opCmp(other.time);
    }
}

/**
  * RateLimiter is a utility to limit rates.
  */
class RateLimiter
{
    private
    {
        RedBlackTree!Parcel parcels;
        Duration window;
        size_t total;
        size_t limit;
        size_t perWindow;
    }

    /**
      * Create a RateLimiter.
      *
      * Params:
      *   limit = the amount to allow in the given window
      *   window = the amount of time to limit rate over
      *
      * Note that a lower window will result in more pauses but more even usage.
      */
    this(size_t limit, Duration window = 1.seconds)
    {
        this.limit = limit;
        this.window = window;
        perWindow = limit * window.total!"seconds";
        parcels = new typeof(parcels);
    }

    /**
      * Limit the rate, taking into account the current operation.
      *
      * Params:
      *   weight = the weight of this operation. For instance, bytes downloaded.
      */
    void limitRate(size_t weight = 1)
    {
        if (limit == 0 || limit == size_t.max)
        {
            // No rate limit requested. Don't bother.
            return;
        }
        auto now = Clock.currTime;
        total += weight;
        parcels.insert(Parcel(now, weight));
        if (total < perWindow)
        {
            // We might be out of date on the total time, but that's okay; we're below limit.
            return;
        }
        auto start = now - window;
        while (!parcels.empty && parcels.front.time < start)
        {
            total -= parcels.front.size;
            parcels.removeFront;
        }
        if (total > perWindow)
        {
            // So we had a limit of, say, 2,000kb / 10s.
            // But we downloaded 2200kb in 10 seconds.
            // This would have been okay in 11 seconds.
            // So we sleep for 1 second and everything is okay.
            auto d = total / cast(double)perWindow;
            auto s = (d - 1) * window.total!"seconds";
            Thread.sleep((cast(long)s).seconds);
        }
    }
}
