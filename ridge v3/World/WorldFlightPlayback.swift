import Foundation

/// Speed is a clock control on the prepared rail, never a terrain rebuild.
/// Integrate the exponential response exactly so 30/60 Hz cover the same distance.
struct WorldFlightPlayback {
    /// Ordinary slow frames retain their elapsed time. A long suspension uses
    /// the fresh display interval so returning to the app cannot skip the tour.
    static func frameSeconds(now:Double,previous:Double,displayInterval:Double)->Double {
        let fallback=displayInterval.isFinite ? max(0,displayInterval) : 0
        let elapsed=now-previous
        return previous>0 && elapsed.isFinite && elapsed>=0 && elapsed<=2 ? elapsed : fallback
    }
    private(set) var speed=0.0
    private(set) var bank:Float=0
    mutating func reset(speed:Double) { self.speed=max(0,speed);bank=0 }
    mutating func advance(seconds:Double,requested:Double,preparedSpeed:Double)->Double {
        let dt=seconds.isFinite ? max(0,seconds) : 0,target=max(0,requested),decay=exp(-dt/0.25)
        let metres=target*dt+(speed-target)*0.25*(1-decay)
        speed=target+(speed-target)*decay
        return metres/max(0.1,preparedSpeed)
    }
    mutating func roll(toward target:Float,seconds:Double)->Float {
        let dt=Float(max(0,min(0.1,seconds))),step=(target-bank)*(1-exp(-dt/0.45)),limit=dt*0.22
        bank+=min(limit,max(-limit,step));return bank
    }
}
