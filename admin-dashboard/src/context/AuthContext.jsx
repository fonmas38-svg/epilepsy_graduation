import { createContext, useContext, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { configureClient } from '../api/client.js';
import { authApi } from '../api/auth.js';

const TOKEN_KEY = 'epi_admin_token';
const USER_KEY = 'epi_admin_user';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => {
    try {
      const urlToken = new URLSearchParams(window.location.search).get('token');
      if (urlToken) {
        localStorage.setItem(TOKEN_KEY, urlToken);
        window.history.replaceState({}, document.title, window.location.pathname);
        return urlToken;
      }
    } catch (_) {}
    return localStorage.getItem(TOKEN_KEY);
  });
  const [user, setUser] = useState(() => {
    try {
      const raw = localStorage.getItem(USER_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  });
  const [loading, setLoading] = useState(true);

  // Keep a ref so the API client's token provider always sees the latest token
  // without needing to be re-registered on every change.
  const tokenRef = useRef(token);
  tokenRef.current = token;

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(USER_KEY);
    setToken(null);
    setUser(null);
  }, []);

  // Register the client's auth hooks exactly once.
  useEffect(() => {
    configureClient({
      tokenProvider: () => tokenRef.current,
      onUnauthorized: () => logout(),
    });
  }, [logout]);

  // On first load, if we have a token, confirm it's still valid and refresh the
  // stored profile. A failure (expired/invalid) cleanly logs out.
  useEffect(() => {
    let cancelled = false;
    async function bootstrap() {
      if (!token) {
        setLoading(false);
        return;
      }
      try {
        const res = await authApi.me();
        if (!cancelled && res && res.user) {
          setUser(res.user);
          localStorage.setItem(USER_KEY, JSON.stringify(res.user));
        }
      } catch {
        if (!cancelled) logout();
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    bootstrap();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const login = useCallback(async (username, password) => {
    const res = await authApi.login(username, password);
    localStorage.setItem(TOKEN_KEY, res.access_token);
    localStorage.setItem(USER_KEY, JSON.stringify(res.user));
    setToken(res.access_token);
    setUser(res.user);
    return res;
  }, []);

  const value = useMemo(
    () => ({
      token,
      user,
      role: user?.role || null,
      isAuthenticated: !!token,
      loading,
      login,
      logout,
    }),
    [token, user, loading, login, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
