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

/// Opt-in, aggregate-only counters for device testing when Instruments cannot
/// attach. No route coordinates are recorded; file writes stay off both the
/// main thread and the render callback. Normal launches do not collect data.
final class WorldFlightFrameMonitor:@unchecked Sendable {
    let isEnabled=ProcessInfo.processInfo.arguments.contains("--ridge-flight-profile")
    private let lock=NSLock(),writer=DispatchQueue(label:"ridge.flight.frame-profile",qos:.utility)
    private var active=false,lastRender:Double?,windowStart=0.0
    private var frames=0,renderTotal=0.0,renderMax=0.0,lateRender=0
    private var ticks=0,tickMax=0.0,lateTicks=0,lowSpeed=Double.infinity,highSpeed=0.0
    private let file=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ridge-flight-profile.jsonl")
    init() {
        if isEnabled { let file=file;writer.async { try? Data().write(to:file,options:.atomic) } }
    }
    func setActive(_ value:Bool) {
        guard isEnabled else { return }
        lock.lock();defer { lock.unlock() }
        guard active != value else { return }
        active=value;lastRender=nil;windowStart=0
        frames=0;renderTotal=0;renderMax=0;lateRender=0
        ticks=0;tickMax=0;lateTicks=0;lowSpeed = .infinity;highSpeed=0
    }
    func recordTick(seconds:Double,speed:Double) {
        guard isEnabled else { return }
        lock.lock();defer { lock.unlock() }
        guard active else { return }
        ticks+=1;tickMax=max(tickMax,seconds);if seconds>0.05 { lateTicks+=1 }
        lowSpeed=min(lowSpeed,speed);highSpeed=max(highSpeed,speed)
    }
    @discardableResult func recordRender(at time:Double)->Bool {
        guard isEnabled else { return false }
        lock.lock()
        guard active else { lock.unlock();return false }
        let previous=lastRender
        lastRender=time
        if windowStart==0 { windowStart=time }
        if let previous,time>previous,time-previous<2 {
            let dt=time-previous
            frames+=1;renderTotal+=dt;renderMax=max(renderMax,dt);if dt>0.05 { lateRender+=1 }
        }
        guard time-windowStart>=2 else { lock.unlock();return true }
        let row:[String:Double]=[
            "seconds":time,"frames":Double(frames),"meanRenderMs":frames>0 ? renderTotal/Double(frames)*1000 : 0,
            "maxRenderMs":renderMax*1000,"lateRender50ms":Double(lateRender),"ticks":Double(ticks),
            "maxMainTickMs":tickMax*1000,"lateMainTicks50ms":Double(lateTicks),
            "minSpeedKmh":lowSpeed.isFinite ? lowSpeed*3.6 : 0,"maxSpeedKmh":highSpeed*3.6]
        windowStart=time;frames=0;renderTotal=0;renderMax=0;lateRender=0
        ticks=0;tickMax=0;lateTicks=0;lowSpeed = .infinity;highSpeed=0
        lock.unlock()
        let file=file
        writer.async {
            guard var data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else { return }
            data.append(10)
            guard let handle=try? FileHandle(forWritingTo:file) else { return }
            defer { try? handle.close() }
            _=try? handle.seekToEnd();try? handle.write(contentsOf:data)
        }
        return true
    }
}
