#!/usr/bin/env python3
"""Make xrizer's IVRCompositor::GetFrameTiming report what was measured.

Upstream answers with constants copied from OpenComposite: 9 ms of GPU time and
one present per frame, whatever the frame really took. Half-Life: Alyx's
automatic fidelity level reads exactly that — it lowers its render resolution
until the reported time fits the frame — so with the constants it stays at its
highest level however slow the frame is (measured on a Vision Pro: 40-50 ms a
frame at 3648x2880 per eye, reported as 9).

What is reported instead is wall time: from the moment the application is
handed the frame (xrWaitFrame returns) to the moment the runtime has taken it
back (xrEndFrame returns). On Klepton's OpenXR runtime that second call waits
for the application's own GPU work, so the span is the frame's CPU and GPU cost
together — which is what a fidelity controller has to fit into the frame.

Run from the xrizer checkout; idempotent against a clean tree at the pinned
revision, and fails loudly if upstream moved.
"""
import pathlib
import sys

p = pathlib.Path("src/compositor.rs")
s = p.read_text()


def sub(old, new):
    global s
    if old not in s:
        sys.exit(f"xrizer-frame-timing: this is not the source it was written for:\n{old}")
    s = s.replace(old, new, 1)


sub("""struct FrameMetrics {
    system_start: Instant,
    index: AtomicU32,
    time: AtomicF64,
}""", """struct FrameMetrics {
    system_start: Instant,
    index: AtomicU32,
    time: AtomicF64,
    // When the frame being rendered was handed to the application, and when
    // the previous one was taken back.
    frame_start: Mutex<Option<Instant>>,
    last_end: Mutex<Option<Instant>>,
    // What the last frame cost the application, and the time between the last
    // two frames, in milliseconds. Smoothed a little: one long frame (a shader
    // compile) should not read as a slow renderer.
    render_ms: AtomicF64,
    interval_ms: AtomicF64,
}""")

sub("""                system_start: Instant::now(),
                index: 0.into(),
                time: 0.0.into(),
            },""", """                system_start: Instant::now(),
                index: 0.into(),
                time: 0.0.into(),
                frame_start: Mutex::new(None),
                last_end: Mutex::new(None),
                render_ms: 0.0.into(),
                interval_ms: 0.0.into(),
            },""")

sub("""        self.openxr
            .display_period_nanos
            .store(display_period, Ordering::Relaxed);
    }""", """        self.openxr
            .display_period_nanos
            .store(display_period, Ordering::Relaxed);
        *self.metrics.frame_start.lock().unwrap() = Some(Instant::now());
    }""")

sub("""        self.metrics.index.fetch_add(1, Ordering::Relaxed);
        self.metrics
            .time
            .store(self.metrics.system_start.elapsed().as_secs_f64());""", """        self.metrics.index.fetch_add(1, Ordering::Relaxed);
        self.metrics
            .time
            .store(self.metrics.system_start.elapsed().as_secs_f64());
        let now = Instant::now();
        let blend = |old: f64, new: f64| if old > 0.0 { old * 0.75 + new * 0.25 } else { new };
        if let Some(start) = self.metrics.frame_start.lock().unwrap().take() {
            let ms = now.duration_since(start).as_secs_f64() * 1000.0;
            self.metrics.render_ms.store(blend(self.metrics.render_ms.load(), ms));
        }
        if let Some(prev) = self.metrics.last_end.lock().unwrap().replace(now) {
            let ms = now.duration_since(prev).as_secs_f64() * 1000.0;
            self.metrics.interval_ms.store(blend(self.metrics.interval_ms.load(), ms));
        }
        // XRIZER_TIMING_LOG=1: what GetFrameTiming is about to be answered with,
        // every 200 frames — the numbers the application's quality controller
        // decides on, which nothing else shows.
        if self.metrics.index.load(Ordering::Relaxed) % 200 == 0
            && std::env::var_os("XRIZER_TIMING_LOG").is_some()
        {
            info!(
                "frame timing: render {:.1} ms, interval {:.1} ms, refresh {:.1} Hz",
                self.metrics.render_ms.load(),
                self.metrics.interval_ms.load(),
                self.openxr.get_refresh_rate()
            );
        }""")

sub("""            set!(m_nNumFramePresents, 1);
            set!(m_nNumMisPresented, 0);
            set!(m_nReprojectionFlags, 0);
            set!(m_flSystemTimeInSeconds, self.metrics.time.load());
            set!(m_flPreSubmitGpuMs, 8.0);
            set!(m_flPostSubmitGpuMs, 1.0);
            set!(m_flTotalRenderGpuMs, 9.0);
""", """            // Measured, not assumed (see FrameMetrics). Before the first frame
            // has been timed the old constants stand in.
            let period_ms = 1000.0 / self.openxr.get_refresh_rate() as f64;
            let render_ms = self.metrics.render_ms.load();
            let interval_ms = self.metrics.interval_ms.load();
            let gpu_ms = if render_ms > 0.0 { render_ms } else { 9.0 };
            // How many display refreshes the frame was on screen for.
            let presents = if interval_ms > 0.0 && period_ms > 0.0 {
                (interval_ms / period_ms).round().clamp(1.0, 16.0) as u32
            } else {
                1
            };
            set!(m_nNumFramePresents, presents);
            set!(m_nNumMisPresented, 0);
            set!(m_nNumDroppedFrames, presents - 1);
            set!(m_nReprojectionFlags, 0);
            set!(m_flSystemTimeInSeconds, self.metrics.time.load());
            set!(m_flPreSubmitGpuMs, (gpu_ms - 1.0).max(0.0) as f32);
            set!(m_flPostSubmitGpuMs, 1.0);
            set!(m_flTotalRenderGpuMs, gpu_ms as f32);
""")

# Refused texture bounds, said. Upstream returns InvalidBounds for anything
# outside 0..1 without a word, and the application then simply has no picture.
# Half-Life: Alyx with `+vr_msaa 2` and a fidelity level above 0 does exactly
# that on every frame (uMax 1.236, vMax 1.283: its render target stays at the
# smallest level's size while it draws the larger one — the picture it submits
# is cropped, so there is nothing right to do with those bounds but refuse).
# The line is what turns "no frames, no error" into a diagnosis.
sub("""        // Superhot passes crazy bounds on startup.
        if !bounds.valid() {
            return vr::EVRCompositorError::InvalidBounds;
        }
""", """        // Superhot passes crazy bounds on startup.
        if !bounds.valid() {
            static SAID: AtomicU32 = AtomicU32::new(0);
            if SAID.fetch_add(1, Ordering::Relaxed) < 2 {
                warn!("Submit: refusing bounds outside 0..1: {bounds:?}");
            }
            return vr::EVRCompositorError::InvalidBounds;
        }
""")

p.write_text(s)
print("xrizer-frame-timing: applied")
