import { STATUS_COLORS, roleLabel, statusLabel } from '../lib/roles.js';

export function RoleBadge({ role }) {
  return <span className={`badge badge--role badge--${role}`}>{roleLabel(role)}</span>;
}

export function StatusBadge({ status }) {
  if (!status) return <span className="badge badge--muted">—</span>;
  const color = STATUS_COLORS[status] || '#64748b';
  return (
    <span className="badge" style={{ color, borderColor: color, background: `${color}1a` }}>
      {statusLabel(status)}
    </span>
  );
}

export function StateBadge({ disabled }) {
  return disabled ? (
    <span className="badge badge--danger">معطّل</span>
  ) : (
    <span className="badge badge--ok">نشط</span>
  );
}
