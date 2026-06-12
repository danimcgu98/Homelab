  // Clock
  function tick() {
    const now = new Date();
    document.getElementById('clock').textContent =
      now.toLocaleTimeString('en-CA', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
    document.getElementById('footer-date').textContent =
      now.toLocaleDateString('en-CA', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  }
  tick();
  setInterval(tick, 1000);

  // Host info
  document.getElementById('info-host').textContent = 'mainframe';

  // Stats polling
  function getStatColor(percent) {
    if (percent >= 90) return '#ff6b6b';
    if (percent >= 70) return '#ffb74d';
    return 'var(--accent)';
  }

  async function fetchStats() {
    try {
      const r = await fetch('/stats');
      const s = await r.json();

      // CPU
      document.getElementById('stat-cpu').textContent = s.cpu + '%';
      document.getElementById('stat-cpu').style.color = getStatColor(s.cpu);
      document.getElementById('stat-cpu-sub').textContent = `load ${s.load.one}`;

      // Temp
      if (s.temp !== null) {
        document.getElementById('stat-temp').textContent = s.temp + '°C';
        document.getElementById('stat-temp').style.color = getStatColor(s.temp > 80 ? 100 : s.temp > 60 ? 75 : 0);
        document.getElementById('stat-temp-sub').textContent = s.temp > 80 ? 'hot' : s.temp > 60 ? 'warm' : 'normal';
      } else {
        document.getElementById('stat-temp').textContent = 'N/A';
      }

      // Memory
      document.getElementById('stat-mem').textContent = s.memory.used + ' GB';
      document.getElementById('stat-mem').style.color = getStatColor(s.memory.percent);
      document.getElementById('stat-mem-sub').textContent = `${s.memory.percent}% of ${s.memory.total} GB`;

      // Disk
      document.getElementById('stat-disk').textContent = s.disk.used + ' GB';
      document.getElementById('stat-disk').style.color = getStatColor(s.disk.percent);
      document.getElementById('stat-disk-sub').textContent = `${s.disk.percent}% of ${s.disk.total} GB`;

      // Uptime
      document.getElementById('stat-uptime').textContent = s.uptime;
      document.getElementById('stat-load-sub').textContent = `load ${s.load.five} avg`;

    } catch {
      document.getElementById('stats-strip').style.opacity = '0.4';
    }
  }

  fetchStats();
  setInterval(fetchStats, 10000);

  // OS section toggles
  function toggleOS(os) {
    const el = document.getElementById('os-' + os);
    const chevron = document.getElementById('chevron-' + os);
    const open = el.style.display === 'none';
    el.style.display = open ? 'block' : 'none';
    chevron.textContent = open ? '▲' : '▼';
  }

  // Cert dropdown
  function toggleCertDropdown() {
    const dropdown = document.getElementById('cert-dropdown');
    const btn = document.getElementById('cert-lock-btn');
    const open = dropdown.classList.toggle('open');
    btn.classList.toggle('open', open);
  }
  // Close dropdown when clicking outside
  document.addEventListener('click', e => {
    const wrap = document.querySelector('.cert-dropdown-wrap');
    if (wrap && !wrap.contains(e.target)) {
      document.getElementById('cert-dropdown').classList.remove('open');
      document.getElementById('cert-lock-btn').classList.remove('open');
    }
  });


  function setView(mode) {
    const grids = document.querySelectorAll('.apps-grid');
    grids.forEach(g => {
      g.classList.toggle('list-view', mode === 'list');
    });
    document.getElementById('btn-grid').classList.toggle('active', mode === 'grid');
    document.getElementById('btn-list').classList.toggle('active', mode === 'list');
    localStorage.setItem('nanolab_view', mode);
  }
  // Restore saved view preference
  const savedView = localStorage.getItem('nanolab_view') || 'grid';
  setView(savedView);

  // App and service counts
  document.getElementById('info-app-count').textContent = document.querySelectorAll('#apps-grid .app-card').length;
  document.getElementById('info-service-count').textContent = document.querySelectorAll('#services-grid .app-card').length;




