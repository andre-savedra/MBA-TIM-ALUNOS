// Um ciclo sequencial. O Node-RED continua responsável pela validação e publicação.
module.exports = async function collect({base, username, password, getToken, setToken, since, series, warn}) {
  async function request(path, options) {
    const response = await fetch(base + path, {
      ...options, redirect: 'error', signal: AbortSignal.timeout(10000)
    });
    if (!response.ok) {
      const error = new Error('HTTP ' + response.status + ' em ' + path.split('?')[0]);
      error.status = response.status;
      error.retryAfter = Number(response.headers.get('retry-after')) || 60;
      throw error;
    }
    if (response.headers.get('x-simulator') !== 'SENAI-MFM') {
      throw new Error('Resposta fora do contrato do simulador');
    }
    return response.status === 204 ? null : response.json();
  }

  async function login() {
    const auth = await request('/auth', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username, password})
    });
    if (!auth?.token) throw new Error('Resposta de login sem token');
    setToken(auth.token);
  }
  async function get(path) {
    if (!getToken()) await login();
    const read = () => request(path, {headers: {Authorization: 'Bearer ' + getToken()}});
    try { return await read(); }
    catch (error) {
      if (error.status !== 401) throw error;
      setToken(null);
      await login();
      return read();
    }
  }

  const visited = new Set();
  for (const site of await get('/customers/sites')) {
    for (const plant of await get('/sites/' + encodeURIComponent(site.siteId) + '/plants')) {
      for (let page = 0; ; page++) {
        const result = await get('/plants/' + encodeURIComponent(plant.plantId) + '/devices?page=' + page + '&perPage=100');
        if (!result) break;
        for (const device of result.devices) {
          const sensors = await get('/devices/' + encodeURIComponent(device.deviceId) + '/sensors');
          for (const {sensorId} of sensors) {
            if (visited.has(sensorId)) continue;
            visited.add(sensorId);
            const last = since(sensorId);
            const filter = last ? '?initial_timestamp=' + encodeURIComponent(last) : '';
            try {
              const body = await get('/sensors/' + encodeURIComponent(sensorId) + '/data' + filter);
              if (body?.sensorId !== sensorId || body.deviceId !== device.deviceId || !Array.isArray(body.data)) {
                throw new Error('Resposta de série incompatível com o sensor solicitado');
              }
              body.data = body.data.filter(row => !last || !(Date.parse(row.timestamp) <= Date.parse(last)))
                .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
              if (body.data.length) series(body);
            } catch (error) {
              if ([401, 429].includes(error.status)) throw error;
              warn(sensorId + ': ' + error.message);
            }
          }
        }
        if (result.devices.length < 100) break;
      }
    }
  }
  return visited.size;
};
