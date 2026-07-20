import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';

const port = Number(process.env.PORT || 3210);
const relaySecret = process.env.RELAY_SECRET || '';
const allowedHosts = new Set(
  (process.env.ALLOWED_HOSTS || '')
    .split(',')
    .map((host) => host.trim().toLowerCase())
    .filter(Boolean)
);
const maxResponseBytes = 8 * 1024 * 1024;

function sendJson(response, status, message) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'
  });
  response.end(JSON.stringify({ error: message }));
}

function safeEquals(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function parseAllowedTarget(value) {
  const target = new URL(value);
  if (target.protocol !== 'https:' || !allowedHosts.has(target.hostname.toLowerCase())) {
    throw new Error('Target is not allowed');
  }
  return target;
}

async function fetchTarget(target, userAgent, redirects = 0) {
  const upstream = await fetch(target, {
    redirect: 'manual',
    signal: AbortSignal.timeout(20_000),
    headers: {
      Accept: '*/*',
      'User-Agent': userAgent?.slice(0, 300) || 'v2rayN/7.23'
    }
  });

  const location = upstream.headers.get('location');
  if (location && [301, 302, 303, 307, 308].includes(upstream.status)) {
    if (redirects >= 3) throw new Error('Too many redirects');
    return fetchTarget(parseAllowedTarget(new URL(location, target).toString()), userAgent, redirects + 1);
  }

  return upstream;
}

const server = http.createServer(async (request, response) => {
  try {
    const incoming = new URL(request.url, 'http://localhost');
    const suppliedSecret = incoming.pathname.startsWith('/api/')
      ? incoming.pathname.slice('/api/'.length)
      : '';

    if (request.method !== 'GET' || !relaySecret || !safeEquals(suppliedSecret, relaySecret)) {
      return sendJson(response, 404, 'Not found');
    }

    const target = parseAllowedTarget(incoming.searchParams.get('url') || '');
    const requestUserAgent = Array.isArray(request.headers['user-agent'])
      ? request.headers['user-agent'][0]
      : request.headers['user-agent'];
    // MiSub uses a dedicated UA for quota requests. Preserve it so providers
    // that vary subscription headers by client return the same data as direct fetches.
    const upstream = await fetchTarget(target, requestUserAgent || incoming.searchParams.get('ua'));
    const declaredLength = Number(upstream.headers.get('content-length') || 0);
    if (declaredLength > maxResponseBytes) return sendJson(response, 413, 'Response is too large');

    const body = Buffer.from(await upstream.arrayBuffer());
    if (body.length > maxResponseBytes) return sendJson(response, 413, 'Response is too large');

    const subscriptionUserInfo = upstream.headers.get('subscription-userinfo');
    const responseHeaders = {
      'Content-Type': upstream.headers.get('content-type') || 'application/octet-stream',
      'Cache-Control': 'no-store',
      'Content-Length': body.length,
      'X-Content-Type-Options': 'nosniff'
    };

    if (subscriptionUserInfo) {
      responseHeaders['Subscription-Userinfo'] = subscriptionUserInfo;
    }

    response.writeHead(upstream.status, responseHeaders);
    response.end(body);
  } catch (error) {
    console.error('Fetch relay request failed:', error.message);
    sendJson(response, 502, 'Upstream fetch failed');
  }
});

server.listen(port, () => {
  console.log(`Fetch relay listening on port ${port}; allowed hosts: ${allowedHosts.size}`);
});
