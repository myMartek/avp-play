#!/usr/bin/env python3
"""Hand the game's loading-screen messages to the host.

Half-Life: Alyx describes its loading screen instead of drawing it: JSON sent
over IVRMailbox to "hlvr/interstitials", a web page SteamVR would display
(begin_loading with the tip and chapter texts, show_message "Press Trigger To
Start", end_loading). Upstream xrizer logs the call and drops it. Here every
message is also written, NUL-terminated, to /dev/klepton-interstitial — a path
Klepton's Linux runtime answers (runtime/linux/kl_lx_interstitial.c) and
nothing else has, so on any other system the open fails and nothing changes.

Run from the xrizer checkout; fails loudly if upstream moved.
"""
import pathlib
import sys

p = pathlib.Path("src/misc_unknown.rs")
s = p.read_text()
old = """            debug!(target: UNKNOWN_TAG, "Entered IVRMailbox::undoc3 with arguments handle: {handle:?}, a: {a:?}, b: {b:?}");
"""
new = old + """            if let Some(b) = b {
                use std::io::Write;
                static SINK: std::sync::Mutex<Option<std::fs::File>> = std::sync::Mutex::new(None);
                let mut sink = SINK.lock().unwrap();
                if sink.is_none() {
                    *sink = std::fs::OpenOptions::new()
                        .write(true)
                        .open("/dev/klepton-interstitial")
                        .ok();
                }
                if let Some(f) = sink.as_mut() {
                    let _ = f.write_all(b.to_bytes_with_nul());
                }
            }
"""
if old not in s:
    sys.exit("xrizer-interstitials: this is not the source it was written for")
p.write_text(s.replace(old, new, 1))
