#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Nano Lab — Provisioning Script
# Run on a fresh Ubuntu 24 Server install as user 'porkchop'
# Redeploys the entire homelab from NAS backup
# ═══════════════════════════════════════════════════════════════

set -e

# ── CONFIGURATION ─────────────────────────────────────────────
USER="porkchop"
HOME_DIR="/home/${USER}"
DOCKER_DIR="${HOME_DIR}/docker"
SCRIPTS_DIR="${HOME_DIR}/scripts"
WWW_DIR="/var/www/homelab"
NAS_IP="192.168.205.141"
NAS_SHARE="homelab-backup"
NAS_MOUNT="/mnt/nas-backup"
NAS_CREDENTIALS="/etc/nas-credentials"
LOG="/var/log/provision.log"

# Pihole config
PIHOLE_PASSWORD="Piholeadmin!@#98"
TZ="America/Chicago"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}" | tee -a "$LOG"; }
ok() { echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOG"; }

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     Nano Lab — Provisioning Script        ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
warn "This script will provision a fresh Ubuntu server."
warn "Ensure you are running as '${USER}' with sudo access."
echo ""
read -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

sudo touch "$LOG"
sudo chown $USER:$USER "$LOG"

# ── STEP 1: SYSTEM PACKAGES ───────────────────────────────────
section "Installing system packages"

sudo apt update -qq
sudo apt install -y \
  curl wget git \
  cifs-utils \
  lm-sensors \
  ufw \
  ca-certificates \
  gnupg \
  libnss3-tools \
  2>/dev/null

ok "System packages installed"

# ── STEP 2: DOCKER ────────────────────────────────────────────
section "Installing Docker"

if command -v docker &>/dev/null; then
  ok "Docker already installed — skipping"
else
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker $USER
  ok "Docker installed"
  warn "NOTE: You may need to log out and back in for Docker group to take effect"
fi

# ── STEP 3: MKCERT ────────────────────────────────────────────
section "Installing mkcert"

if command -v mkcert &>/dev/null; then
  ok "mkcert already installed — skipping"
else
  curl -Lo /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
  chmod +x /tmp/mkcert
  sudo mv /tmp/mkcert /usr/local/bin/mkcert
  mkcert -install
  ok "mkcert installed"
fi

# ── STEP 4: K10TEMP MODULE ────────────────────────────────────
section "Loading k10temp sensor module"

sudo modprobe k10temp 2>/dev/null || true
if ! grep -q "k10temp" /etc/modules 2>/dev/null; then
  echo "k10temp" | sudo tee -a /etc/modules
fi
ok "k10temp module loaded"

# ── STEP 5: DIRECTORY STRUCTURE ───────────────────────────────
section "Creating directory structure"

mkdir -p \
  "${DOCKER_DIR}/authelia/config" \
  "${DOCKER_DIR}/collector-backend/data" \
  "${DOCKER_DIR}/cookbook-backend/data" \
  "${DOCKER_DIR}/ledger-backend/data" \
  "${DOCKER_DIR}/calories-backend/data" \
  "${DOCKER_DIR}/calendar-backend/data" \
  "${DOCKER_DIR}/navidrome/data" \
  "${DOCKER_DIR}/navidrome/music" \
  "${DOCKER_DIR}/npm/data" \
  "${DOCKER_DIR}/npm/letsencrypt" \
  "${DOCKER_DIR}/pihole-unbound/unbound" \
  "${DOCKER_DIR}/pihole-unbound/pihole/etc-pihole" \
  "${DOCKER_DIR}/pihole-unbound/pihole/etc-dnsmasq.d" \
  "${DOCKER_DIR}/saad-backend/data" \
  "${DOCKER_DIR}/stats-backend" \
  "${DOCKER_DIR}/webserver" \
  "${SCRIPTS_DIR}"

sudo mkdir -p "${WWW_DIR}/saad" "${WWW_DIR}/cookbook" "${WWW_DIR}/collector" "${WWW_DIR}/ledger" "${WWW_DIR}/calories" "${WWW_DIR}/calendar"
sudo chown -R $USER:$USER "${WWW_DIR}"

sudo mkdir -p "${NAS_MOUNT}"

ok "Directories created"

# ── STEP 6: WRITE SOURCE FILES ────────────────────────────────
section "Writing backend source files"

# ── SAAD BACKEND ──────────────────────────────────────────────
cat > "${DOCKER_DIR}/saad-backend/package.json" << 'EOF'
{
  "name": "saad-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/saad-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3000
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/saad-backend/server.js" << 'EOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/periods.json';
app.use(express.json());
app.use(cors());
function readPeriods() {
  if (!fs.existsSync(DATA_FILE)) return [];
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return []; }
}
function writePeriods(periods) { fs.writeFileSync(DATA_FILE, JSON.stringify(periods, null, 2)); }
app.get('/api/periods', (req, res) => { res.json(readPeriods()); });
app.post('/api/periods', (req, res) => {
  const { startDate, endDate } = req.body;
  if (!startDate) return res.status(400).json({ error: 'startDate required' });
  const periods = readPeriods();
  const period = { id: Date.now().toString(), startDate, endDate: endDate || null };
  periods.push(period);
  writePeriods(periods);
  res.status(201).json(period);
});
app.put('/api/periods/:id', (req, res) => {
  const periods = readPeriods();
  const idx = periods.findIndex(p => p.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  periods[idx] = { ...periods[idx], ...req.body };
  writePeriods(periods);
  res.json(periods[idx]);
});
app.delete('/api/periods/:id', (req, res) => {
  writePeriods(readPeriods().filter(p => p.id !== req.params.id));
  res.json({ ok: true });
});
app.listen(3000, () => console.log('Saad API running on port 3000'));
EOF

cat > "${DOCKER_DIR}/saad-backend/docker-compose.yml" << 'EOF'
services:
  saad-api:
    build: .
    container_name: saad-api
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - ./data:/data
EOF

# ── COOKBOOK BACKEND ──────────────────────────────────────────
cat > "${DOCKER_DIR}/cookbook-backend/package.json" << 'EOF'
{
  "name": "cookbook-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/cookbook-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3001
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/cookbook-backend/server.js" << 'EOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/recipes.json';
app.use(express.json());
app.use(cors());
function readRecipes() {
  if (!fs.existsSync(DATA_FILE)) return [];
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return []; }
}
function writeRecipes(r) { fs.writeFileSync(DATA_FILE, JSON.stringify(r, null, 2)); }
app.get('/cookbook-api/recipes', (req, res) => { res.json(readRecipes()); });
app.post('/cookbook-api/recipes', (req, res) => {
  const { name, ingredients, instructions, rating } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  const recipes = readRecipes();
  const recipe = { id: Date.now().toString(), name, ingredients: ingredients || [], instructions: instructions || '', rating: rating || 0, createdAt: new Date().toISOString() };
  recipes.unshift(recipe);
  writeRecipes(recipes);
  res.status(201).json(recipe);
});
app.put('/cookbook-api/recipes/:id', (req, res) => {
  const recipes = readRecipes();
  const idx = recipes.findIndex(r => r.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  recipes[idx] = { ...recipes[idx], ...req.body };
  writeRecipes(recipes);
  res.json(recipes[idx]);
});
app.delete('/cookbook-api/recipes/:id', (req, res) => {
  writeRecipes(readRecipes().filter(r => r.id !== req.params.id));
  res.json({ ok: true });
});
app.listen(3001, () => console.log('Cookbook API running on port 3001'));
EOF

cat > "${DOCKER_DIR}/cookbook-backend/docker-compose.yml" << 'EOF'
services:
  cookbook-api:
    build: .
    container_name: cookbook-api
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - ./data:/data
EOF

# ── COLLECTOR BACKEND ─────────────────────────────────────────
cat > "${DOCKER_DIR}/collector-backend/package.json" << 'EOF'
{
  "name": "collector-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/collector-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3002
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/collector-backend/server.js" << 'EOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/collector.json';
app.use(express.json());
app.use(cors());
function readData() {
  if (!fs.existsSync(DATA_FILE)) return { collections: [], items: [] };
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return { collections: [], items: [] }; }
}
function writeData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2)); }
app.get('/collector-api/collections', (req, res) => {
  const { collections, items } = readData();
  res.json(collections.map(c => ({ ...c, itemCount: items.filter(i => i.collectionId === c.id).length })));
});
app.post('/collector-api/collections', (req, res) => {
  const { name, description, icon } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  const data = readData();
  const collection = { id: Date.now().toString(), name, description: description || '', icon: icon || '📦', createdAt: new Date().toISOString() };
  data.collections.unshift(collection);
  writeData(data);
  res.status(201).json({ ...collection, itemCount: 0 });
});
app.put('/collector-api/collections/:id', (req, res) => {
  const data = readData();
  const idx = data.collections.findIndex(c => c.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data.collections[idx] = { ...data.collections[idx], ...req.body };
  writeData(data);
  res.json(data.collections[idx]);
});
app.delete('/collector-api/collections/:id', (req, res) => {
  const data = readData();
  data.collections = data.collections.filter(c => c.id !== req.params.id);
  data.items = data.items.filter(i => i.collectionId !== req.params.id);
  writeData(data);
  res.json({ ok: true });
});
app.get('/collector-api/collections/:id/items', (req, res) => {
  const { items } = readData();
  res.json(items.filter(i => i.collectionId === req.params.id));
});
app.post('/collector-api/collections/:id/items', (req, res) => {
  const { name, description, notes, condition, quantity, acquiredDate } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  const data = readData();
  const item = { id: Date.now().toString(), collectionId: req.params.id, name, description: description || '', notes: notes || '', condition: condition || '', quantity: quantity || 1, acquiredDate: acquiredDate || null, createdAt: new Date().toISOString() };
  data.items.unshift(item);
  writeData(data);
  res.status(201).json(item);
});
app.put('/collector-api/items/:id', (req, res) => {
  const data = readData();
  const idx = data.items.findIndex(i => i.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data.items[idx] = { ...data.items[idx], ...req.body };
  writeData(data);
  res.json(data.items[idx]);
});
app.delete('/collector-api/items/:id', (req, res) => {
  const data = readData();
  data.items = data.items.filter(i => i.id !== req.params.id);
  writeData(data);
  res.json({ ok: true });
});
app.listen(3002, () => console.log('Collector API running on port 3002'));
EOF

cat > "${DOCKER_DIR}/collector-backend/docker-compose.yml" << 'EOF'
services:
  collector-api:
    build: .
    container_name: collector-api
    restart: unless-stopped
    ports:
      - "3002:3002"
    volumes:
      - ./data:/data
EOF

# ── STATS BACKEND ─────────────────────────────────────────────
cat > "${DOCKER_DIR}/stats-backend/package.json" << 'EOF'
{
  "name": "stats-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/stats-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
RUN apk add --no-cache lm-sensors
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
EXPOSE 3003
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/stats-backend/server.js" << 'JSEOF'
const express = require('express');
const os = require('os');
const cors = require('cors');
const { execSync } = require('child_process');
const app = express();
app.use(cors());
function getCpuUsage() {
  return new Promise(resolve => {
    const cpus1 = os.cpus();
    setTimeout(() => {
      const cpus2 = os.cpus();
      let totalIdle = 0, totalTick = 0;
      for (let i = 0; i < cpus1.length; i++) {
        const idle = cpus2[i].times.idle - cpus1[i].times.idle;
        const total = Object.values(cpus2[i].times).reduce((a,b)=>a+b,0) - Object.values(cpus1[i].times).reduce((a,b)=>a+b,0);
        totalIdle += idle; totalTick += total;
      }
      resolve(Math.round(100 - (totalIdle / totalTick * 100)));
    }, 500);
  });
}
function getCpuTemp() {
  try {
    const output = execSync('sensors 2>/dev/null', { timeout: 3000 }).toString();
    const tctl = output.match(/Tctl:\s+\+?([\d.]+)°C/);
    if (tctl) return Math.round(parseFloat(tctl[1]));
    const pkg = output.match(/Package id 0:\s+\+?([\d.]+)°C/);
    if (pkg) return Math.round(parseFloat(pkg[1]));
    const any = output.match(/\+?([\d.]+)°C/);
    if (any) return Math.round(parseFloat(any[1]));
    return null;
  } catch { return null; }
}
function getMemory() {
  const total = os.totalmem(), free = os.freemem(), used = total - free;
  return { total: Math.round(total/1024/1024/1024*10)/10, used: Math.round(used/1024/1024/1024*10)/10, percent: Math.round((used/total)*100) };
}
function getDisk() {
  try {
    const out = execSync("df -B1 / | tail -1").toString().trim().split(/\s+/);
    const total = parseInt(out[1]), used = parseInt(out[2]);
    return { total: Math.round(total/1024/1024/1024*10)/10, used: Math.round(used/1024/1024/1024*10)/10, percent: Math.round((used/total)*100) };
  } catch { return null; }
}
function getUptime() {
  const s = os.uptime(), d = Math.floor(s/86400), h = Math.floor((s%86400)/3600), m = Math.floor((s%3600)/60);
  if (d > 0) return `${d}d ${h}h`; if (h > 0) return `${h}h ${m}m`; return `${m}m`;
}
function getLoad() {
  const [one, five, fifteen] = os.loadavg();
  return { one: Math.round(one*100)/100, five: Math.round(five*100)/100, fifteen: Math.round(fifteen*100)/100 };
}
app.get('/stats', async (req, res) => {
  const [cpu] = await Promise.all([getCpuUsage()]);
  res.json({ cpu, temp: getCpuTemp(), memory: getMemory(), disk: getDisk(), uptime: getUptime(), load: getLoad() });
});
app.listen(3003, () => console.log('Stats API running on port 3003'));
JSEOF

cat > "${DOCKER_DIR}/stats-backend/docker-compose.yml" << 'EOF'
services:
  stats-api:
    build: .
    container_name: stats-api
    restart: unless-stopped
    network_mode: host
    volumes:
      - /sys/class/thermal:/sys/class/thermal:ro
      - /proc:/proc:ro
    environment:
      - NODE_ENV=production
EOF

# ── LEDGER BACKEND ────────────────────────────────────────────
cat > "${DOCKER_DIR}/ledger-backend/package.json" << 'EOF'
{
  "name": "ledger-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/ledger-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3004
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/ledger-backend/server.js" << 'EOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/ledger.json';
app.use(express.json());
app.use(cors());
function readData() {
  if (!fs.existsSync(DATA_FILE)) return [];
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return []; }
}
function writeData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2)); }
app.get('/ledger-api/entries', (req, res) => { res.json(readData()); });
app.post('/ledger-api/entries', (req, res) => {
  const { description, amount, date, category, type, addedBy } = req.body;
  if (!description || !amount || !date || !type) return res.status(400).json({ error: 'Missing required fields' });
  const data = readData();
  const entry = { id: Date.now().toString(), description, amount: parseFloat(amount), date, category: category || 'Other', type, addedBy: addedBy || '', createdAt: new Date().toISOString() };
  data.push(entry);
  writeData(data);
  res.status(201).json(entry);
});
app.put('/ledger-api/entries/:id', (req, res) => {
  const data = readData();
  const idx = data.findIndex(e => e.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data[idx] = { ...data[idx], ...req.body, amount: parseFloat(req.body.amount) };
  writeData(data);
  res.json(data[idx]);
});
app.delete('/ledger-api/entries/:id', (req, res) => {
  writeData(readData().filter(e => e.id !== req.params.id));
  res.json({ ok: true });
});
app.listen(3004, () => console.log('Ledger API running on port 3004'));
EOF

cat > "${DOCKER_DIR}/ledger-backend/docker-compose.yml" << 'EOF'
services:
  ledger-api:
    build: .
    container_name: ledger-api
    restart: unless-stopped
    ports:
      - "3004:3004"
    volumes:
      - ./data:/data
EOF

# ── CALORIES BACKEND ──────────────────────────────────────────
cat > "${DOCKER_DIR}/calories-backend/package.json" << 'EOF'
{
  "name": "calories-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/calories-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3006
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/calories-backend/server.js" << 'JSEOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/calories.json';
app.use(express.json());
app.use(cors());
function readData() {
  if (!fs.existsSync(DATA_FILE)) return { users: [], entries: [] };
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return { users: [], entries: [] }; }
}
function writeData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2)); }
app.get('/calories-api/users', (req, res) => { res.json(readData().users); });
app.post('/calories-api/users', (req, res) => {
  const { name, emoji, heightFeet, heightInches, weightLbs, goalWeightLbs, age, gender, calorieGoal } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  const data = readData();
  if (data.users.find(u => u.name.toLowerCase() === name.toLowerCase()))
    return res.status(409).json({ error: 'User already exists' });
  const user = { id: Date.now().toString(), name, emoji: emoji || '🧑', heightFeet, heightInches, weightLbs, goalWeightLbs, age, gender, calorieGoal };
  data.users.push(user);
  writeData(data);
  res.status(201).json(user);
});
app.put('/calories-api/users/:id', (req, res) => {
  const data = readData();
  const idx = data.users.findIndex(u => u.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data.users[idx] = { ...data.users[idx], ...req.body };
  writeData(data);
  res.json(data.users[idx]);
});
app.delete('/calories-api/users/:id', (req, res) => {
  const data = readData();
  data.users = data.users.filter(u => u.id !== req.params.id);
  data.entries = data.entries.filter(e => e.userId !== req.params.id);
  writeData(data);
  res.json({ ok: true });
});
app.get('/calories-api/entries', (req, res) => {
  const { userId, date } = req.query;
  let entries = readData().entries;
  if (userId) entries = entries.filter(e => e.userId === userId);
  if (date) entries = entries.filter(e => e.date === date);
  res.json(entries);
});
app.post('/calories-api/entries', (req, res) => {
  const { userId, foodName, calories, meal, date } = req.body;
  if (!userId || !foodName || !calories || !meal || !date)
    return res.status(400).json({ error: 'Missing required fields' });
  const data = readData();
  const entry = { id: Date.now().toString(), userId, foodName, calories: parseInt(calories), meal, date, createdAt: new Date().toISOString() };
  data.entries.push(entry);
  writeData(data);
  res.status(201).json(entry);
});
app.put('/calories-api/entries/:id', (req, res) => {
  const data = readData();
  const idx = data.entries.findIndex(e => e.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data.entries[idx] = { ...data.entries[idx], ...req.body, calories: parseInt(req.body.calories) };
  writeData(data);
  res.json(data.entries[idx]);
});
app.delete('/calories-api/entries/:id', (req, res) => {
  const data = readData();
  data.entries = data.entries.filter(e => e.id !== req.params.id);
  writeData(data);
  res.json({ ok: true });
});
app.get('/calories-api/search', async (req, res) => {
  const { q } = req.query;
  if (!q) return res.status(400).json({ error: 'query required' });
  try {
    const url = `https://world.openfoodfacts.org/cgi/search.pl?search_terms=${encodeURIComponent(q)}&search_simple=1&action=process&json=1&page_size=20`;
    const response = await fetch(url);
    const data = await response.json();
    const results = (data.products || [])
      .filter(p => p.product_name && p.nutriments)
      .map(p => {
        const n = p.nutriments;
        const cal = n['energy-kcal_100g'] || n['energy-kcal'] || (n['energy_100g'] ? Math.round(n['energy_100g'] / 4.184) : null);
        if (!cal) return null;
        return { name: p.product_name, brand: p.brands || '', caloriesPer100g: Math.round(cal), servingSize: p.serving_size || '100g' };
      })
      .filter(Boolean)
      .slice(0, 8);
    res.json(results);
  } catch { res.status(500).json({ error: 'Search failed' }); }
});
app.listen(3006, () => console.log('Calories API running on port 3006'));
JSEOF

cat > "${DOCKER_DIR}/calories-backend/docker-compose.yml" << 'EOF'
services:
  calories-api:
    build: .
    container_name: calories-api
    restart: unless-stopped
    ports:
      - "3006:3006"
    volumes:
      - ./data:/data
EOF

ok "Backend source files written"

# ── CALENDAR BACKEND ──────────────────────────────────────────
cat > "${DOCKER_DIR}/calendar-backend/package.json" << 'EOF'
{
  "name": "calendar-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "express": "^4.18.2" }
}
EOF

cat > "${DOCKER_DIR}/calendar-backend/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
RUN mkdir -p /data
EXPOSE 3007
CMD ["node", "server.js"]
EOF

cat > "${DOCKER_DIR}/calendar-backend/server.js" << 'JSEOF'
const express = require('express');
const fs = require('fs');
const cors = require('cors');
const app = express();
const DATA_FILE = '/data/calendar.json';
app.use(express.json());
app.use(cors());
function readData() {
  if (!fs.existsSync(DATA_FILE)) return { events: [] };
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return { events: [] }; }
}
function writeData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2)); }
app.get('/calendar-api/events', (req, res) => {
  const { month, year } = req.query;
  let { events } = readData();
  if (month && year) {
    events = events.filter(e => {
      const d = new Date(e.startTime);
      return d.getMonth() + 1 === parseInt(month) && d.getFullYear() === parseInt(year);
    });
  }
  res.json(events);
});
app.post('/calendar-api/events', (req, res) => {
  const { title, startTime, endTime, description, color } = req.body;
  if (!title || !startTime) return res.status(400).json({ error: 'title and startTime required' });
  const data = readData();
  const event = { id: Date.now().toString(), title, startTime, endTime: endTime || null, description: description || '', color: color || '#c8f264', notified: false, createdAt: new Date().toISOString() };
  data.events.push(event);
  writeData(data);
  res.status(201).json(event);
});
app.put('/calendar-api/events/:id', (req, res) => {
  const data = readData();
  const idx = data.events.findIndex(e => e.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  data.events[idx] = { ...data.events[idx], ...req.body };
  writeData(data);
  res.json(data.events[idx]);
});
app.delete('/calendar-api/events/:id', (req, res) => {
  const data = readData();
  data.events = data.events.filter(e => e.id !== req.params.id);
  writeData(data);
  res.json({ ok: true });
});
app.listen(3007, () => console.log('Calendar API running on port 3007'));
JSEOF

cat > "${DOCKER_DIR}/calendar-backend/docker-compose.yml" << 'EOF'
services:
  calendar-api:
    build: .
    container_name: calendar-api
    restart: unless-stopped
    ports:
      - "3007:3007"
    volumes:
      - ./data:/data
EOF

# Write notify script
cat > "${SCRIPTS_DIR}/calendar-notify.js" << 'JSEOF'
#!/usr/bin/env node
const DISCORD_WEBHOOK = process.env.CALENDAR_WEBHOOK || '';
const DATA_FILE = '/data/calendar.json';
const LOG_FILE = '/var/log/homelab-calendar.log';
const fs = require('fs');
function log(msg) { fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${msg}\n`); }
function readData() {
  if (!fs.existsSync(DATA_FILE)) return { events: [] };
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); } catch { return { events: [] }; }
}
function writeData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2)); }
async function sendDiscord(event) {
  const [datePart, timePart] = event.startTime.split('T');
  const [year, month, day] = datePart.split('-');
  const [hour, minute] = timePart.split(':');
  const h = parseInt(hour);
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 || 12;
  const timeStr = `${h12}:${minute} ${ampm}`;
  const days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
  const d = new Date(`${datePart}T12:00:00`);
  const dateStr = `${days[d.getUTCDay()]}, ${months[parseInt(month)-1]} ${parseInt(day)}`;
  const body = { embeds: [{ title: `🗓️ Reminder — ${event.title}`, color: 0xc8f264, fields: [{ name: 'When', value: `${dateStr} at ${timeStr}`, inline: true }, { name: 'In', value: '2 hours', inline: true }], footer: { text: 'Nano Lab Calendar' } }] };
  if (event.description) body.embeds[0].description = event.description;
  const res = await fetch(DISCORD_WEBHOOK, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return res.ok;
}
async function main() {
  const now = Date.now();
  const twoHours = 2 * 60 * 60 * 1000;
  const windowMin = twoHours - 5 * 60 * 1000;
  const windowMax = twoHours + 5 * 60 * 1000;
  const tzOffset = '-05:00';
  const data = readData();
  let changed = false;
  for (const event of data.events) {
    if (event.repeat && event.repeat.type === 'weekly') {
      const startBase = new Date(event.startTime + tzOffset).getTime();
      const notifiedDates = event.notifiedDates || [];
      let occurrence = startBase;
      while (occurrence < now - 3 * 60 * 60 * 1000) occurrence += 7 * 24 * 60 * 60 * 1000;
      const diff = occurrence - now;
      if (diff >= windowMin && diff <= windowMax) {
        const occDateStr = new Date(occurrence).toISOString().split('T')[0];
        if (!notifiedDates.includes(occDateStr)) {
          if (!event.repeat.endDate || occDateStr <= event.repeat.endDate) {
            log(`Sending reminder for recurring: ${event.title} on ${occDateStr}`);
            const ok = await sendDiscord({ ...event, startTime: occDateStr + 'T' + event.startTime.split('T')[1] });
            if (ok) { event.notifiedDates = [...notifiedDates, occDateStr]; changed = true; log(`✓ Notified: ${event.title} (${occDateStr})`); }
            else { log(`✗ Failed to notify: ${event.title}`); }
          }
        }
      }
    } else {
      if (event.notified) continue;
      const startStr = event.startTime.includes('+') || event.startTime.includes('Z') ? event.startTime : event.startTime + tzOffset;
      const start = new Date(startStr).getTime();
      const diff = start - now;
      if (diff >= windowMin && diff <= windowMax) {
        log(`Sending reminder for: ${event.title}`);
        const ok = await sendDiscord(event);
        if (ok) { event.notified = true; changed = true; log(`✓ Notified: ${event.title}`); }
        else { log(`✗ Failed to notify: ${event.title}`); }
      }
    }
  }
  if (changed) writeData(data);
}
main().catch(err => log(`ERROR: ${err.message}`));
JSEOF

ok "Calendar backend written"

# ── STEP 7: DOCKER COMPOSE FILES ──────────────────────────────
section "Writing docker-compose files"

cat > "${DOCKER_DIR}/authelia/docker-compose.yml" << 'EOF'
services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped
    ports:
      - "9091:9091"
    volumes:
      - ./config:/config
    environment:
      - TZ=America/Chicago
EOF

cat > "${DOCKER_DIR}/navidrome/docker-compose.yml" << 'EOF'
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    ports:
      - "4533:4533"
    environment:
      ND_SCANSCHEDULE: 1h
      ND_LOGLEVEL: info
      ND_SESSIONTIMEOUT: 24h
      ND_BASEURL: ""
      TZ: America/Chicago
    volumes:
      - ./data:/data
      - ./music:/music:ro
EOF

cat > "${DOCKER_DIR}/npm/docker-compose.yml" << 'EOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

cat > "${DOCKER_DIR}/pihole-unbound/.env" << EOF
WEBPASSWORD=${PIHOLE_PASSWORD}
TZ=${TZ}
EOF

cat > "${DOCKER_DIR}/pihole-unbound/docker-compose.yml" << 'EOF'
services:
  unbound:
    image: mvance/unbound:latest
    container_name: unbound
    restart: unless-stopped
    volumes:
      - ./unbound:/etc/unbound
    networks:
      dns_net:
        ipv4_address: 172.20.0.2

  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: "${TZ}"
      WEBPASSWORD: "${WEBPASSWORD}"
      PIHOLE_DNS_: "172.20.0.2#5335"
      DNSSEC: "true"
      REV_SERVER: "true"
      REV_SERVER_CIDR: "192.168.205.0/24"
      REV_SERVER_TARGET: "192.168.205.1"
      REV_SERVER_DOMAIN: "local"
      DNSMASQ_LISTENING: "all"
      PIHOLE_DNS_USER_OPTS: "--local-service=0"
    volumes:
      - ./pihole/etc-pihole:/etc/pihole
      - ./pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    depends_on:
      - unbound
    networks:
      dns_net:
        ipv4_address: 172.20.0.3

networks:
  dns_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
EOF

cat > "${DOCKER_DIR}/webserver/docker-compose.yml" << 'EOF'
services:
  webserver:
    image: nginx:alpine
    container_name: webserver
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/www/homelab:/var/www/homelab:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOF

cat > "${DOCKER_DIR}/webserver/nginx.conf" << 'EOF'
server {
    listen 8181;
    root /var/www/homelab;
    index index.html;
    location / { try_files $uri $uri/ =404; }
    location /saad/ { alias /var/www/homelab/saad/; try_files $uri $uri/ /saad/index.html; }
    location /cookbook/ { alias /var/www/homelab/cookbook/; try_files $uri $uri/ /cookbook/index.html; }
    location /collector/ { alias /var/www/homelab/collector/; try_files $uri $uri/ /collector/index.html; }
    location /api/ { proxy_pass http://127.0.0.1:3000/api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /cookbook-api/ { proxy_pass http://127.0.0.1:3001/cookbook-api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /collector-api/ { proxy_pass http://127.0.0.1:3002/collector-api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /stats { proxy_pass http://127.0.0.1:3003/stats; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /ledger/ { alias /var/www/homelab/ledger/; try_files $uri $uri/ /ledger/index.html; }
    location /ledger-api/ { proxy_pass http://127.0.0.1:3004/ledger-api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /calories/ { alias /var/www/homelab/calories/; try_files $uri $uri/ /calories/index.html; }
    location /calories-api/ { proxy_pass http://127.0.0.1:3006/calories-api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /calendar/ { alias /var/www/homelab/calendar/; try_files $uri $uri/ /calendar/index.html; }
    location /calendar-api/ { proxy_pass http://127.0.0.1:3007/calendar-api/; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    gzip on;
    gzip_types text/plain text/css application/javascript application/json;
    gzip_min_length 1024;
}
server {
    listen 8282;
    location = /rootCA.pem { root /var/www/homelab; default_type application/x-pem-file; add_header Content-Disposition 'attachment; filename="rootCA.pem"'; }
    location / { return 404; }
}
EOF

ok "Docker compose files written"

# ── STEP 8: SCRIPTS ───────────────────────────────────────────
section "Writing scripts"

cat > "${SCRIPTS_DIR}/backup.sh" << 'EOF'
#!/bin/bash
BACKUP_ROOT="/mnt/nas-backup/homelab"
RETAIN=7
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
LOG_FILE="/var/log/homelab-backup.log"
HOSTNAME=$(hostname)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/secrets.env" ] && source "${SCRIPT_DIR}/secrets.env"
DISCORD_WEBHOOK="${BACKUP_WEBHOOK:-}"
SUCCESS=0; FAILED=0; FAILED_LIST=""; RETRY_LIST=""; RESULTS=""
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
discord() {
  curl -s -X POST "$DISCORD_WEBHOOK" -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"$2\",\"description\":\"$3\",\"color\":$1,\"footer\":{\"text\":\"${HOSTNAME} · $(date '+%Y-%m-%d %H:%M')\"}}]}" > /dev/null
}
log "═══════════════════════════════════════"
log "Starting backup → ${BACKUP_DIR}"
if ! mountpoint -q /mnt/nas-backup; then
  log "ERROR: NAS is not mounted. Aborting."
  discord 15158332 "🔴 Backup Failed — NAS Not Mounted" "The NAS is not mounted on \`${HOSTNAME}\`. No backup was taken."
  exit 1
fi
mkdir -p "${BACKUP_DIR}"
backup_source() {
  local NAME="$1"; local SRC="$2"; local EXCLUDE="$3"; local USE_SUDO="$4"
  local DEST="${BACKUP_DIR}/${NAME}"
  if [ ! -d "$SRC" ]; then log "⚠ ${NAME}: source not found"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: source not found\n"; return; fi
  mkdir -p "$DEST"
  run_rsync() {
    if [ "$USE_SUDO" = "sudo" ]; then sudo rsync -a --quiet $EXCLUDE "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"
    elif [ -n "$EXCLUDE" ]; then rsync -a --quiet $EXCLUDE "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"
    else rsync -a --quiet "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"; fi
  }
  if run_rsync; then log "✓ ${NAME}"; ((SUCCESS++)); RESULTS="${RESULTS}✅ **${NAME}**\n"
  else
    log "⚠ ${NAME}: failed — retrying..."; rm -rf "$DEST"; mkdir -p "$DEST"; RETRY_LIST="${RETRY_LIST}${NAME}, "
    if run_rsync; then log "✓ ${NAME}: retry succeeded"; ((SUCCESS++)); RESULTS="${RESULTS}✅ **${NAME}** _(retry)_\n"
    else log "✗ ${NAME}: retry failed"; rm -rf "$DEST"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: failed after retry\n"; fi
  fi
}
backup_source "saad"        "/home/porkchop/docker/saad-backend/data"       ""                                   ""
backup_source "boggler"     "/home/porkchop/docker/cookbook-backend/data"   ""                                   ""
backup_source "collector"   "/home/porkchop/docker/collector-backend/data"  ""                                   ""
backup_source "ledger"      "/home/porkchop/docker/ledger-backend/data"     ""                                   ""
backup_source "authelia"    "/home/porkchop/docker/authelia/config"         ""                                   "sudo"
backup_source "pihole"      "/home/porkchop/docker/pihole-unbound/pihole"   ""                                   "sudo"
backup_source "navidrome"   "/home/porkchop/docker/navidrome/data"          "--exclude=cache/ --exclude=plugins/" ""
backup_source "npm"         "/home/porkchop/docker/npm/data"                ""                                   ""
backup_source "vaultwarden" "/home/porkchop/docker/vaultwarden/data"        ""                                   ""
backup_source "uptime-kuma" "/home/porkchop/docker/uptime-kuma/data"        ""                                   ""
backup_source "portainer"   "/home/porkchop/docker/portainer/data"          ""                                   "sudo"
backup_source "frontend"    "/var/www/homelab"                              ""                                   ""
backup_source "calories"    "/home/porkchop/docker/calories-backend/data"   ""                                   ""
backup_source "calendar"    "/home/porkchop/docker/calendar-backend/data"   ""                                   ""
cat > "${BACKUP_DIR}/manifest.txt" << MANIFEST
Backup: ${TIMESTAMP}
Host: ${HOSTNAME}
Sources backed up: ${SUCCESS}
Sources failed: ${FAILED}
MANIFEST
log "Backup complete — ${SUCCESS} sources backed up, ${FAILED} failed"
BACKUP_COUNT=$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETAIN" ]; then
  DELETE_COUNT=$((BACKUP_COUNT - RETAIN))
  ls -1d "${BACKUP_ROOT}"/*/ | sort | head -n "${DELETE_COUNT}" | while read -r OLD; do rm -rf "$OLD"; log "  Deleted: $(basename $OLD)"; done
fi
RETAINED=$(ls -1d ${BACKUP_ROOT}/*/ 2>/dev/null | wc -l)
log "Done. Backups retained: ${RETAINED}"
log "═══════════════════════════════════════"
RETRY_NOTE=""; [ -n "$RETRY_LIST" ] && RETRY_NOTE="\n\n⚠️ **Retried:** ${RETRY_LIST%, }"
if [ "$FAILED" -eq 0 ]; then
  discord 3066993 "✅ Backup Complete — ${TIMESTAMP}" "All **${SUCCESS}** sources backed up on \`${HOSTNAME}\`. ${RETAINED} backup(s) retained.\n\n${RESULTS}${RETRY_NOTE}"
else
  discord 15158332 "🔴 Backup Failed — ${TIMESTAMP}" "**${FAILED} source(s) failed** on \`${HOSTNAME}\`.\n\n${RESULTS}${RETRY_NOTE}\n\nCheck \`/var/log/homelab-backup.log\`."
fi
EOF

chmod +x "${SCRIPTS_DIR}/backup.sh"

# Restore script
cat > "${SCRIPTS_DIR}/restore.sh" << 'RSEOF'
#!/bin/bash
BACKUP_ROOT="/mnt/nas-backup/homelab"
LOG_FILE="/var/log/homelab-backup.log"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESTORE: $1" | tee -a "$LOG_FILE"; }
APPS=("Saad (Period Tracker)|saad-api|/home/porkchop/docker/saad-backend/data|/home/porkchop/docker/saad-backend" "Boggler (Recipes)|cookbook-api|/home/porkchop/docker/cookbook-backend/data|/home/porkchop/docker/cookbook-backend" "Collector|collector-api|/home/porkchop/docker/collector-backend/data|/home/porkchop/docker/collector-backend" "Ledger (Budget)|ledger-api|/home/porkchop/docker/ledger-backend/data|/home/porkchop/docker/ledger-backend" "Authelia|authelia|/home/porkchop/docker/authelia/config|/home/porkchop/docker/authelia" "Pi-hole|pihole|/home/porkchop/docker/pihole-unbound/pihole|/home/porkchop/docker/pihole-unbound" "Navidrome|navidrome|/home/porkchop/docker/navidrome/data|/home/porkchop/docker/navidrome" "NPM|npm|/home/porkchop/docker/npm/data|/home/porkchop/docker/npm")
APP_KEYS=("saad" "boggler" "collector" "ledger" "authelia" "pihole" "navidrome" "npm")
echo ""; echo -e "${BOLD}${CYAN}Nano Lab — Restore Tool${NC}"; echo ""
if ! mountpoint -q /mnt/nas-backup; then echo -e "${RED}ERROR: NAS not mounted.${NC}"; exit 1; fi
echo -e "${BOLD}Available backups:${NC}"; echo ""
BACKUPS=(); i=1
while IFS= read -r dir; do
  NAME=$(basename "$dir")
  if [ -f "${dir}/manifest.txt" ]; then SOURCES=$(grep "Sources backed up" "${dir}/manifest.txt" | cut -d: -f2 | tr -d ' '); echo -e "  ${CYAN}[$i]${NC} ${NAME}  (${SOURCES} sources)"; else echo -e "  ${CYAN}[$i]${NC} ${NAME}"; fi
  BACKUPS+=("$NAME"); ((i++))
done < <(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r)
[ ${#BACKUPS[@]} -eq 0 ] && echo -e "${RED}No backups found.${NC}" && exit 1
echo ""; read -p "Select backup number [1-${#BACKUPS[@]}]: " BACKUP_NUM
SELECTED_BACKUP="${BACKUPS[$((BACKUP_NUM-1))]}"; BACKUP_DIR="${BACKUP_ROOT}/${SELECTED_BACKUP}"
echo ""; echo -e "Selected: ${BOLD}${SELECTED_BACKUP}${NC}"; echo ""
echo -e "${BOLD}Which apps to restore?${NC}"; echo ""; echo -e "  ${CYAN}[0]${NC} All apps"
for j in "${!APPS[@]}"; do IFS='|' read -r DISPLAY _ _ _ <<< "${APPS[$j]}"; KEY="${APP_KEYS[$j]}"; [ -d "${BACKUP_DIR}/${KEY}" ] && echo -e "  ${CYAN}[$((j+1))]${NC} ${DISPLAY}" || echo -e "  ${CYAN}[$((j+1))]${NC} ${DISPLAY} ${YELLOW}(not in backup)${NC}"; done
echo ""; read -p "Enter numbers separated by spaces or 0 for all: " -a SELECTIONS
RESTORE_LIST=()
if [[ " ${SELECTIONS[@]} " =~ " 0 " ]]; then for j in "${!APPS[@]}"; do RESTORE_LIST+=("$j"); done
else for SEL in "${SELECTIONS[@]}"; do [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le ${#APPS[@]} ] && RESTORE_LIST+=("$((SEL-1))"); done; fi
[ ${#RESTORE_LIST[@]} -eq 0 ] && echo -e "${RED}No valid apps selected.${NC}" && exit 1
echo ""; echo -e "${YELLOW}Will restore from ${BOLD}${SELECTED_BACKUP}${NC}${YELLOW}:${NC}"; echo ""
for idx in "${RESTORE_LIST[@]}"; do IFS='|' read -r DISPLAY _ _ _ <<< "${APPS[$idx]}"; echo -e "  • ${DISPLAY}"; done
echo ""; echo -e "${RED}${BOLD}WARNING: This will overwrite current data.${NC}"; echo ""
read -p "Type 'yes' to confirm: " CONFIRM; [ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0
echo ""; log "Starting restore from ${SELECTED_BACKUP}"
for idx in "${RESTORE_LIST[@]}"; do
  IFS='|' read -r DISPLAY CONTAINER DATA_PATH COMPOSE_DIR <<< "${APPS[$idx]}"; KEY="${APP_KEYS[$idx]}"; BACKUP_SRC="${BACKUP_DIR}/${KEY}"
  [ ! -d "$BACKUP_SRC" ] && echo -e "${YELLOW}⚠ ${DISPLAY}: not in backup${NC}" && continue
  echo -e "${CYAN}Restoring ${DISPLAY}...${NC}"
  docker stop "${CONTAINER}" 2>/dev/null || true
  rsync -a --delete "${BACKUP_SRC}/" "${DATA_PATH}/" 2>> "$LOG_FILE"
  cd "${COMPOSE_DIR}" && docker compose up -d 2>/dev/null || docker start "${CONTAINER}" 2>/dev/null || true
  echo -e "  ${GREEN}✓ ${DISPLAY} restored${NC}"; log "✓ ${KEY} restored"
done
echo ""; echo -e "${GREEN}${BOLD}Restore complete!${NC}"; log "Restore complete from ${SELECTED_BACKUP}"; echo ""
RSEOF

chmod +x "${SCRIPTS_DIR}/restore.sh"
sudo cp "${SCRIPTS_DIR}/restore.sh" /usr/local/bin/restore

sudo touch /var/log/homelab-backup.log
sudo chown $USER:$USER /var/log/homelab-backup.log

# Verify script
cat > "${SCRIPTS_DIR}/verify-backup.sh" << 'EOF'
#!/bin/bash
BACKUP_ROOT="/mnt/nas-backup/homelab"
LOG_FILE="/var/log/homelab-backup-verify.log"
HOSTNAME=$(hostname)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/secrets.env" ] && source "${SCRIPT_DIR}/secrets.env"
DISCORD_WEBHOOK="${BACKUP_WEBHOOK:-}"
SOURCES=("saad|periods.json" "boggler|recipes.json" "collector|collector.json" "ledger|exists" "authelia|configuration.yml" "pihole|etc-pihole" "navidrome|." "npm|." "vaultwarden|db.sqlite3" "uptime-kuma|kuma.db" "portainer|portainer.db" "frontend|index.html" "calories|calories.json" "calendar|calendar.json")
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
discord() {
  curl -s -X POST "$DISCORD_WEBHOOK" -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"$2\",\"description\":\"$3\",\"color\":$1,\"footer\":{\"text\":\"${HOSTNAME} · $(date '+%Y-%m-%d %H:%M')\"}}]}" > /dev/null
}
log "═══════════════════════════════════════"
log "Starting backup verification"
if ! mountpoint -q /mnt/nas-backup; then
  log "ERROR: NAS not mounted"; discord 15158332 "🔴 Backup Verification Failed" "NAS not mounted on \`${HOSTNAME}\`."; exit 1
fi
LATEST=$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r | head -1)
if [ -z "$LATEST" ]; then
  log "ERROR: No backups found"; discord 15158332 "🔴 Backup Verification Failed" "No backups found on \`${HOSTNAME}\`."; exit 1
fi
BACKUP_NAME=$(basename "$LATEST"); log "Verifying backup: ${BACKUP_NAME}"
PASSED=0; FAILED=0; FAILED_LIST=""; RESULTS=""
for SOURCE in "${SOURCES[@]}"; do
  IFS='|' read -r NAME CHECK <<< "$SOURCE"
  BACKUP_DIR="${LATEST}${NAME}"
  if [ ! -d "$BACKUP_DIR" ]; then log "  ✗ ${NAME}: directory missing"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: directory missing\n"; continue; fi
  if [ "$CHECK" = "exists" ]; then
    log "  ✓ ${NAME}: directory exists"; ((PASSED++)); RESULTS="${RESULTS}✅ **${NAME}**: directory exists\n"
  elif [ "$CHECK" = "." ]; then
    FC=$(find "$BACKUP_DIR" -type f | wc -l)
    if [ "$FC" -eq 0 ]; then log "  ✗ ${NAME}: empty"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: empty\n"
    else log "  ✓ ${NAME}: ${FC} files"; ((PASSED++)); RESULTS="${RESULTS}✅ **${NAME}**: ${FC} files\n"; fi
  elif [ -d "${BACKUP_DIR}/${CHECK}" ]; then
    FC=$(find "${BACKUP_DIR}/${CHECK}" -type f | wc -l)
    if [ "$FC" -eq 0 ]; then log "  ✗ ${NAME}: ${CHECK}/ empty"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}/\` empty\n"
    else log "  ✓ ${NAME}: ${CHECK}/ (${FC} files)"; ((PASSED++)); RESULTS="${RESULTS}✅ **${NAME}**: \`${CHECK}/\` (${FC} files)\n"; fi
  else
    if [ ! -f "${BACKUP_DIR}/${CHECK}" ]; then log "  ✗ ${NAME}: ${CHECK} missing"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}\` missing\n"
    elif [ ! -s "${BACKUP_DIR}/${CHECK}" ]; then log "  ✗ ${NAME}: ${CHECK} empty"; ((FAILED++)); FAILED_LIST="${FAILED_LIST}${NAME}, "; RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}\` empty\n"
    else SZ=$(du -h "${BACKUP_DIR}/${CHECK}" | cut -f1); log "  ✓ ${NAME}: ${CHECK} (${SZ})"; ((PASSED++)); RESULTS="${RESULTS}✅ **${NAME}**: \`${CHECK}\` (${SZ})\n"; fi
  fi
done
log "Verification complete — ${PASSED} passed, ${FAILED} failed"
if [ "$FAILED" -eq 0 ]; then
  discord 3066993 "✅ Backup Verified — ${BACKUP_NAME}" "All **${PASSED}** sources verified on \`${HOSTNAME}\`.\n\n${RESULTS}"; exit 0
fi
FAILED_LIST="${FAILED_LIST%, }"
discord 15158332 "🔴 Backup Verification Failed — ${BACKUP_NAME}" "**${FAILED} source(s) failed** on \`${HOSTNAME}\`.\n\n${RESULTS}\nAttempting auto-restore..."
log "Attempting auto-restore for: ${FAILED_LIST}"
RESTORE_SUCCESS=0; RESTORE_FAILED=0; RESTORE_RESULTS=""
restore_source() {
  local NAME="$1"; local CONTAINER="$2"; local DATA_PATH="$3"; local COMPOSE_DIR="$4"
  local BACKUP_SRC="${LATEST}${NAME}"
  if [ ! -d "$BACKUP_SRC" ]; then ((RESTORE_FAILED++)); RESTORE_RESULTS="${RESTORE_RESULTS}❌ **${NAME}**: backup missing\n"; return; fi
  docker stop "$CONTAINER" 2>/dev/null || true
  rsync -a --delete "${BACKUP_SRC}/" "${DATA_PATH}/" 2>> "$LOG_FILE"
  cd "$COMPOSE_DIR" && docker compose up -d 2>/dev/null || docker start "$CONTAINER" 2>/dev/null || true
  log "  ✓ ${NAME} restored"; ((RESTORE_SUCCESS++)); RESTORE_RESULTS="${RESTORE_RESULTS}✅ **${NAME}**: restored\n"
}
IFS=', ' read -ra FAILED_NAMES <<< "$FAILED_LIST"
for NAME in "${FAILED_NAMES[@]}"; do
  case "$NAME" in
    saad)        restore_source "saad"        "saad-api"      "/home/porkchop/docker/saad-backend/data"      "/home/porkchop/docker/saad-backend" ;;
    boggler)     restore_source "boggler"     "cookbook-api"  "/home/porkchop/docker/cookbook-backend/data"  "/home/porkchop/docker/cookbook-backend" ;;
    collector)   restore_source "collector"   "collector-api" "/home/porkchop/docker/collector-backend/data" "/home/porkchop/docker/collector-backend" ;;
    ledger)      restore_source "ledger"      "ledger-api"    "/home/porkchop/docker/ledger-backend/data"    "/home/porkchop/docker/ledger-backend" ;;
    authelia)    restore_source "authelia"    "authelia"      "/home/porkchop/docker/authelia/config"        "/home/porkchop/docker/authelia" ;;
    pihole)      restore_source "pihole"      "pihole"        "/home/porkchop/docker/pihole-unbound/pihole"  "/home/porkchop/docker/pihole-unbound" ;;
    navidrome)   restore_source "navidrome"   "navidrome"     "/home/porkchop/docker/navidrome/data"         "/home/porkchop/docker/navidrome" ;;
    npm)         restore_source "npm"         "npm"           "/home/porkchop/docker/npm/data"               "/home/porkchop/docker/npm" ;;
    vaultwarden) restore_source "vaultwarden" "vaultwarden"   "/home/porkchop/docker/vaultwarden/data"       "/home/porkchop/docker/vaultwarden" ;;
    uptime-kuma) restore_source "uptime-kuma" "uptime-kuma"   "/home/porkchop/docker/uptime-kuma/data"       "/home/porkchop/docker/uptime-kuma" ;;
    portainer)   restore_source "portainer"   "portainer"     "/home/porkchop/docker/portainer/data"         "/home/porkchop/docker/portainer" ;;
    calories)    restore_source "calories"    "calories-api"  "/home/porkchop/docker/calories-backend/data"  "/home/porkchop/docker/calories-backend" ;;
    calendar)    restore_source "calendar"    "calendar-api"  "/home/porkchop/docker/calendar-backend/data"  "/home/porkchop/docker/calendar-backend" ;;
    frontend)    rsync -a --delete "${LATEST}frontend/" "/var/www/homelab/" 2>> "$LOG_FILE"; ((RESTORE_SUCCESS++)); RESTORE_RESULTS="${RESTORE_RESULTS}✅ **frontend**: restored\n" ;;
  esac
done
if [ "$RESTORE_FAILED" -eq 0 ]; then
  discord 16776960 "🟡 Auto-Restore Complete — ${BACKUP_NAME}" "Restore succeeded for all **${RESTORE_SUCCESS}** source(s) on \`${HOSTNAME}\`. Please verify services manually.\n\n${RESTORE_RESULTS}"
else
  discord 15158332 "🔴 Auto-Restore Partially Failed — ${BACKUP_NAME}" "Some sources could not be restored on \`${HOSTNAME}\`. Manual intervention required.\n\n${RESTORE_RESULTS}"
fi
log "═══════════════════════════════════════"
EOF

chmod +x "${SCRIPTS_DIR}/verify-backup.sh"

# Log files
sudo touch /var/log/homelab-backup-verify.log
sudo chown $USER:$USER /var/log/homelab-backup-verify.log

# Sudoers rule for rsync (needed for authelia, pihole, portainer backups)
echo "${USER} ALL=(ALL) NOPASSWD: /usr/bin/rsync" | sudo tee /etc/sudoers.d/${USER}-rsync
sudo chmod 440 /etc/sudoers.d/${USER}-rsync
ok "Sudoers rule added for rsync"

ok "Scripts written"

# ── STEP 9: UFW RULES ─────────────────────────────────────────
section "Configuring UFW firewall"

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow in on tailscale0 to any port 22
sudo ufw allow from 192.168.205.0/24 to any port 22

sudo ufw allow from 192.168.205.0/24 to any port 80
sudo ufw allow from 100.64.0.0/10    to any port 80

sudo ufw allow from 192.168.205.0/24 to any port 53
sudo ufw allow from 100.64.0.0/10    to any port 53

sudo ufw allow from 192.168.205.0/24 to any port 81
sudo ufw allow from 100.64.0.0/10    to any port 81

sudo ufw allow from 172.16.0.0/12    to any port 8181

sudo ufw allow from 192.168.205.0/24 to any port 443
sudo ufw allow from 100.64.0.0/10    to any port 443

sudo ufw allow from 192.168.205.0/24 to any port 9091
sudo ufw allow from 100.64.0.0/10    to any port 9091
sudo ufw allow from 172.16.0.0/12    to any port 9091

sudo ufw allow from 192.168.205.0/24 to any port 8282
sudo ufw allow from 100.64.0.0/10    to any port 8282

sudo ufw --force enable
ok "UFW configured"

# ── STEP 10: FSTAB & NAS MOUNT ────────────────────────────────
section "Setting up NAS mount"

echo "Setting up NAS credentials file..."
read -p "Enter NAS username for nas_admin: " NAS_USER
read -s -p "Enter NAS password: " NAS_PASS
echo ""

sudo bash -c "cat > ${NAS_CREDENTIALS} << EOF
username=${NAS_USER}
password=${NAS_PASS}
EOF"
sudo chmod 600 "${NAS_CREDENTIALS}"

# Add to fstab if not already there
if ! grep -q "nas-backup" /etc/fstab; then
  echo "//${NAS_IP}/${NAS_SHARE} ${NAS_MOUNT} cifs credentials=${NAS_CREDENTIALS},uid=1000,gid=1000,iocharset=utf8,_netdev 0 0" | sudo tee -a /etc/fstab
fi

sudo mount -a || warn "NAS mount failed — check NAS is online and credentials are correct"
mountpoint -q "${NAS_MOUNT}" && ok "NAS mounted at ${NAS_MOUNT}" || warn "NAS not mounted — continue manually"

# ── STEP 11: CRONTAB ──────────────────────────────────────────
section "Setting up cron jobs"

(crontab -l 2>/dev/null | grep -v "backup.sh\|verify-backup.sh\|calendar-notify"; \
  echo "0 2 * * * /bin/bash /home/porkchop/scripts/backup.sh"; \
  echo "0 6 * * 0 /bin/bash /home/porkchop/scripts/verify-backup.sh"; \
  echo "* * * * * /usr/bin/docker exec calendar-api node /app/notify.js") | crontab -
ok "Cron jobs set — backup 2 AM daily, verify 6 AM Sunday, calendar notify every minute"

# Copy notify script into calendar container after it starts
# (done after step 13 — see start_service for calendar-backend)

# ── STEP 12: RESTORE FROM BACKUP ─────────────────────────────
section "Restoring from latest backup"

if mountpoint -q "${NAS_MOUNT}"; then
  LATEST=$(ls -1d "${NAS_MOUNT}/homelab"/*/ 2>/dev/null | sort -r | head -1)
  if [ -n "$LATEST" ]; then
    log "Restoring from $(basename $LATEST)"

    restore_data() {
      local NAME="$1"; local DEST="$2"; local EXCLUDE="$3"
      local SRC="${LATEST}${NAME}"
      if [ -d "$SRC" ]; then
        mkdir -p "$DEST"
        rsync -a $EXCLUDE "${SRC}/" "${DEST}/" 2>/dev/null || true
        ok "Restored ${NAME}"
      else
        warn "${NAME}: not in backup"
      fi
    }

    restore_data "saad"      "${DOCKER_DIR}/saad-backend/data"              ""
    restore_data "boggler"   "${DOCKER_DIR}/cookbook-backend/data"          ""
    restore_data "collector" "${DOCKER_DIR}/collector-backend/data"         ""
    restore_data "ledger"    "${DOCKER_DIR}/ledger-backend/data"            ""
    restore_data "authelia"  "${DOCKER_DIR}/authelia/config"                ""
    restore_data "pihole"    "${DOCKER_DIR}/pihole-unbound/pihole"          ""
    restore_data "navidrome" "${DOCKER_DIR}/navidrome/data"                 "--exclude=cache/ --exclude=plugins/"
    restore_data "npm"       "${DOCKER_DIR}/npm/data"                       ""
    restore_data "vaultwarden" "${DOCKER_DIR}/vaultwarden/data"             ""
    restore_data "uptime-kuma" "${DOCKER_DIR}/uptime-kuma/data"             ""
    restore_data "calories"  "${DOCKER_DIR}/calories-backend/data"          ""
    restore_data "calendar"  "${DOCKER_DIR}/calendar-backend/data"          ""
    # Frontend files
    if [ -d "${LATEST}frontend" ]; then
      rsync -a "${LATEST}frontend/" "${WWW_DIR}/" 2>/dev/null || true
      ok "frontend restored"
    fi
  else
    warn "No backups found on NAS — starting fresh"
  fi
else
  warn "NAS not mounted — skipping restore"
fi

# ── STEP 13: BUILD AND START CONTAINERS ───────────────────────
section "Building and starting containers"

start_service() {
  local NAME="$1"; local DIR="$2"
  log "Starting ${NAME}..."
  cd "$DIR" && docker compose up -d --build 2>/dev/null && ok "${NAME} started" || warn "${NAME} failed to start"
}

start_service "pihole-unbound"  "${DOCKER_DIR}/pihole-unbound"
start_service "npm"             "${DOCKER_DIR}/npm"
start_service "authelia"        "${DOCKER_DIR}/authelia"
start_service "saad-backend"    "${DOCKER_DIR}/saad-backend"
start_service "cookbook-backend" "${DOCKER_DIR}/cookbook-backend"
start_service "collector-backend" "${DOCKER_DIR}/collector-backend"
start_service "ledger-backend"  "${DOCKER_DIR}/ledger-backend"
start_service "calories-backend" "${DOCKER_DIR}/calories-backend"
start_service "calendar-backend" "${DOCKER_DIR}/calendar-backend"

# Copy notify script into calendar container
docker cp "${SCRIPTS_DIR}/calendar-notify.js" calendar-api:/app/notify.js 2>/dev/null || warn "Could not copy notify.js into calendar-api — do this manually after deploy"
sudo touch /var/log/homelab-calendar.log
sudo chown $USER:$USER /var/log/homelab-calendar.log
ok "Calendar notify script deployed"
start_service "stats-backend"   "${DOCKER_DIR}/stats-backend"
start_service "navidrome"       "${DOCKER_DIR}/navidrome"
start_service "vaultwarden"     "${DOCKER_DIR}/vaultwarden"
start_service "uptime-kuma"     "${DOCKER_DIR}/uptime-kuma"
start_service "portainer"       "${DOCKER_DIR}/portainer"
start_service "webserver"       "${DOCKER_DIR}/webserver"

# ── STEP 14: GENERATE SSL CERT ────────────────────────────────
section "Generating SSL certificate"

mkdir -p "${HOME_DIR}/certs"
cd "${HOME_DIR}/certs"
mkcert nanolab.local auth.nanolab.local pihole.nanolab.local nas.nanolab.local music.nanolab.local 192.168.205.137 192.168.205.141 100.97.3.94 2>/dev/null
cp $(mkcert -CAROOT)/rootCA.pem "${WWW_DIR}/rootCA.pem"
ok "SSL certificate generated"

# ── DONE ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         Provisioning Complete!            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Manual steps required:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Install Tailscale and authenticate:"
echo -e "     curl -fsSL https://tailscale.com/install.sh | sh"
echo -e "     sudo tailscale up --accept-routes --advertise-routes=192.168.205.141/32"
echo ""
echo -e "  ${CYAN}2.${NC} Upload SSL certificate to NPM:"
echo -e "     Open http://192.168.205.137:81"
echo -e "     SSL Certificates → Add Custom → upload ~/certs/nanolab.local+7.pem and key"
echo ""
echo -e "  ${CYAN}3.${NC} If NPM backup was restored, proxy hosts should already be configured."
echo -e "     Verify each proxy host has the new SSL cert selected."
echo -e "     Re-edit 5.conf manually if needed (Authelia forward auth config)."
echo ""
echo -e "  ${CYAN}4.${NC} Add Pi-hole local DNS records (if not restored from backup):"
echo -e "     nanolab.local       → 192.168.205.137"
echo -e "     auth.nanolab.local  → 192.168.205.137"
echo -e "     pihole.nanolab.local → 192.168.205.137"
echo -e "     music.nanolab.local → 192.168.205.137"
echo -e "     nas.nanolab.local   → 192.168.205.141"
echo ""
echo -e "  ${CYAN}5.${NC} Copy frontend files from Windows to server:"
echo -e "     /var/www/homelab/index.html (dashboard)"
echo -e "     /var/www/homelab/saad/"
echo -e "     /var/www/homelab/cookbook/"
echo -e "     /var/www/homelab/collector/"
echo -e "     /var/www/homelab/ledger/"
echo -e "     /var/www/homelab/calories/"
echo -e "     /var/www/homelab/calendar/"
echo ""
echo -e "  ${CYAN}6.${NC} Set Firewalla DNS to new server IP if changed"
echo ""
echo -e "${YELLOW}Log saved to: ${LOG}${NC}"
echo ""
