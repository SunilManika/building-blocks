// Security headers and browser-facing request checks for the wizard API.
// There is no sign-in: the wizard is meant to be reached only from the machine that runs it (loopback) or from a
// network you already trust. These checks stop *other web pages* in the operator's browser from driving the API.

// The SPA only needs its own scripts; inline styles are used by React style attributes.
export const APP_CSP = [
  "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data:",
  "connect-src 'self'", "object-src 'none'", "base-uri 'none'", "form-action 'self'", "frame-ancestors 'none'",
].join('; ');

// Generated fleet reports use inline scripts/styles. `sandbox` (without allow-same-origin) gives them an opaque
// origin, so a report can never call the wizard's API.
export const REPORT_CSP = [
  "default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "img-src data:",
  'sandbox allow-scripts allow-downloads',
].join('; ');

export function securityHeaders({ secureCookies = false } = {}) {
  return (req, res, next) => {
    res.setHeader('Content-Security-Policy', APP_CSP);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    if (req.secure || secureCookies) res.setHeader('Strict-Transport-Security', 'max-age=15552000');
    if (req.path.startsWith('/api/')) res.setHeader('Cache-Control', 'no-store');
    next();
  };
}

const UNSAFE = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

function originAllowed(req, allowedOrigins) {
  const origin = req.headers.origin;
  if (!origin) return true; // same-origin navigation or a non-browser client
  if (allowedOrigins.includes(origin)) return true;
  let host;
  try { host = new URL(origin).host; } catch { return false; }
  if (host === req.headers.host) return true;
  return Boolean(req.app.get('trust proxy')) && host === req.headers['x-forwarded-host'];
}

/**
 * Rejects cross-origin state-changing requests (a malicious page cannot make the browser POST here) and any
 * request body that is not JSON. Also serves /api/healthz.
 */
export function installApiGuards(app, { allowedOrigins = [] } = {}) {
  app.use('/api', (req, res, next) => {
    if (UNSAFE.has(req.method)) {
      if (!originAllowed(req, allowedOrigins)) {
        return res.status(403).json({ message: 'Cross-origin request blocked.', code: 'bad_origin' });
      }
      // The browser sets Sec-Fetch-Site itself; "cross-site" can never come from this wizard's own page.
      if (req.headers['sec-fetch-site'] === 'cross-site') {
        return res.status(403).json({ message: 'Cross-site request blocked.', code: 'bad_origin' });
      }
      // req.is() is null for body-less requests (e.g. cancel), which are fine; a body of another type is not.
      if (req.is('application/json') === false) {
        return res.status(415).json({ message: 'Content-Type must be application/json.', code: 'bad_content_type' });
      }
    }
    next();
  });
  app.get('/api/healthz', (_req, res) => res.json({ ok: true }));
}
