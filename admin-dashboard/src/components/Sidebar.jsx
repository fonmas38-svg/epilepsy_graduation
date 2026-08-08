import { NavLink } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';

// Role-aware navigation. Admin sees the full system; a doctor sees only the
// screens they're permitted to use (their patients + profile).
const NAV = [
  { to: '/', label: 'نظرة عامة', icon: '📊', roles: ['admin'], end: true },
  { to: '/doctors', label: 'الأطباء', icon: '🩺', roles: ['admin'] },
  { to: '/patients', label: 'المرضى', icon: '🧑‍⚕️', roles: ['admin'] },
  { to: '/assignments', label: 'الإسناد', icon: '🔗', roles: ['admin'] },
  { to: '/users', label: 'كل الحسابات', icon: '👥', roles: ['admin'] },
  { to: '/audit', label: 'سجل النشاط', icon: '🧾', roles: ['admin'] },
  { to: '/my-patients', label: 'مرضاي', icon: '🧑‍⚕️', roles: ['doctor', 'admin'] },
];

export default function Sidebar() {
  const { role } = useAuth();
  const items = NAV.filter((n) => n.roles.includes(role));

  return (
    <aside className="sidebar">
      <div className="sidebar__brand">
        <span className="sidebar__brand-mark">🧠</span>
        <div>
          <div className="sidebar__brand-title">مراقبة الصرع</div>
          <div className="sidebar__brand-sub">لوحة الإدارة</div>
        </div>
      </div>
      <nav className="sidebar__nav">
        {items.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            end={n.end}
            className={({ isActive }) =>
              isActive ? 'sidebar__link sidebar__link--active' : 'sidebar__link'
            }
          >
            <span className="sidebar__link-icon">{n.icon}</span>
            <span>{n.label}</span>
          </NavLink>
        ))}
      </nav>
    </aside>
  );
}
