import { useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import FormField from '../components/FormField.jsx';

export default function LoginPage() {
  const { login, isAuthenticated } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const from = location.state?.from?.pathname || '/';

  if (isAuthenticated) {
    navigate(from, { replace: true });
  }

  const onSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      await login(username.trim(), password);
      navigate(from, { replace: true });
    } catch (err) {
      setError(err?.message || 'تعذّر تسجيل الدخول');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login-page">
      <form className="login-card" onSubmit={onSubmit}>
        <div className="login-card__brand">
          <div className="login-card__mark">🧠</div>
          <div className="login-card__title">لوحة إدارة مراقبة الصرع</div>
          <div className="login-card__sub">تسجيل الدخول للمدير أو الطبيب</div>
        </div>

        {error && <div className="login-error">{error}</div>}

        <FormField
          label="اسم المستخدم"
          name="username"
          value={username}
          onChange={setUsername}
          required
          autoFocus
        />
        <FormField
          label="كلمة المرور"
          name="password"
          type="password"
          value={password}
          onChange={setPassword}
          required
        />
        <button className="btn btn--primary" type="submit" disabled={busy} style={{ width: '100%' }}>
          {busy ? 'جارٍ الدخول…' : 'دخول'}
        </button>

        <div className="login-hint">
          الحساب الافتراضي للمدير يُنشأ تلقائياً عند أول تشغيل للخادم.
        </div>
      </form>
    </div>
  );
}
