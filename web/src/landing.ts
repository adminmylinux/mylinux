/* One orchestrated moment: the machine boots. A few kernel lines run in the
   window, then the desktop takes over. Reduced-motion users see the desktop
   right away. Also: copy buttons for the install commands and the menu clock. */

const bootLines = [
  "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x612f0230]",
  "[    0.000000] Linux version 6.18.7 (buildroot) aarch64",
  "[    0.000000] Machine model: linux,dummy-virt",
  "[    0.014212] virtio-pci 0000:00:01.0: enabling device (0000 -> 0002)",
  "[    0.318905] [drm] Initialized virtio_gpu 0.1.0 for 0000:00:02.0 on minor 0",
  "[    0.402117] virtio_blk virtio3: [vda] 33554432 512-byte logical blocks (16.0 GB)",
  "[    0.611440] Freeing unused kernel memory: 4032K",
  "[    0.612003] Run /init as init process",
  "Mounting /root from the apps disk ... done",
  "Starting myshell (Qt 6.11, eglfs_kms, llvmpipe) ...",
];

function boot() {
  const log = document.getElementById("bootlog");
  const shot = document.getElementById("desktop");
  if (!log || !shot) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) {
    shot.classList.add("on");
    return;
  }
  let i = 0;
  const tick = () => {
    if (i < bootLines.length) {
      log.textContent += bootLines[i++] + "\n";
      setTimeout(tick, i < 4 ? 60 : 110);
    } else {
      setTimeout(() => shot.classList.add("on"), 350);
    }
  };
  setTimeout(tick, 400);
}

function copyButtons() {
  for (const btn of document.querySelectorAll<HTMLButtonElement>("button[data-copy]")) {
    btn.addEventListener("click", async () => {
      const target = document.getElementById(btn.dataset.copy!);
      const text = target?.textContent?.replace(/^\$ /gm, "").trim() ?? "";
      try {
        await navigator.clipboard.writeText(text);
        const was = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(() => (btn.textContent = was), 1400);
      } catch {
        btn.textContent = "Select and copy";
      }
    });
  }
}

function clock() {
  const el = document.getElementById("clock");
  if (!el) return;
  const fmt = () => {
    const d = new Date();
    el.textContent = d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }) + "  " +
      d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  };
  fmt();
  setInterval(fmt, 30000);
}

boot();
copyButtons();
clock();
