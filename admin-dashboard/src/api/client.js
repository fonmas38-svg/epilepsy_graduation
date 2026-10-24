// Thin fetch wrapper around the FastAPI REST API.
//
// * Base URL: VITE_API_BASE_URL if set, else '/api' (the Vite dev proxy).
// * Auth: a token provider is injected by AuthContext so every request carries
//   the current JWT without threading it through every call site.
// * Errors: non-2xx responses throw an ApiError carrying status + server detail,
//   and a 401 triggers the registered onUnauthorized handler (auto-logout).

const RAW_BASE = import.meta.env.VITE_API_BASE_URL || '';
export const API_BASE = RAW_BASE ? RAW_BASE.replace(/\/$/, '') : (import.meta.env.DEV ? '/api' : '');

let _tokenProvider = () => null;
let _onUnauthorized = () => {};

export function configureClient({ tokenProvider, onUnauthorized }) {
  if (tokenProvider) _tokenProvider = tokenProvider;
  if (onUnauthorized) _onUnauthorized = onUnauthorized;
}

export class ApiError extends Error {
  constructor(message, status, detail) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.detail = detail;
  }
}

async function request(method, path, body) {
  const headers = { 'Content-Type': 'application/json' };
  const token = _tokenProvider();
  if (token) headers['Authorization'] = `Bearer ${token}`;

  let res;
  try {
    res = await fetch(`${API_BASE}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (networkErr) {
    throw new ApiError('تعذّر الاتصال بالخادم', 0, String(networkErr));
  }

  if (res.status === 401 && token === _tokenProvider()) {
    _onUnauthorized();
  }

  let payload = null;
  const text = await res.text();
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { detail: text };
    }
  }

  if (!res.ok) {
    const detail =
      (payload && (payload.detail || payload.message)) || res.statusText;
    throw new ApiError(
      typeof detail === 'string' ? detail : 'حدث خطأ في الطلب',
      res.status,
      detail,
    );
  }
  return payload;
}

export const api = {
  get: (path) => request('GET', path),
  post: (path, body) => request('POST', path, body),
  patch: (path, body) => request('PATCH', path, body),
  del: (path, body) => request('DELETE', path, body),
};
