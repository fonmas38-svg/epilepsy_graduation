import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { roleLabel } from '../lib/roles.js';
import { initials } from '../lib/format.js';

export default function Topbar() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();

  const onLogout = () => {
    logout();
    navigate('/login', { replace: true });
  };

  return (
    <header className="topbar">
      <div className="topbar__title">
        <span style={{ fontSize: '18px' }}>🏥</span>
        <span>منظومة الرقابة السريرية والتشخيص العصبي الذكي</span>
        <span className="badge badge--ok" style={{ marginInlineStart: '12px', fontSize: '11px', padding: '3px 8px' }}>
          النظام متصل ونشط
        </span>
      </div>
      <div className="topbar__right">
        <div className="topbar__user">
          <div className="avatar">{initials(user?.name)}</div>
          <div className="topbar__user-meta">
            <div className="topbar__user-name">{user?.name || 'مدير النظام'}</div>
            <div className="topbar__user-role">{roleLabel(user?.role)}</div>
          </div>
        </div>
        <button className="btn btn--ghost btn--sm" onClick={onLogout}>
          تسجيل الخروج
        </button>
      </div>
    </header>
  );
}
