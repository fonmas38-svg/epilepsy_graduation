export default function StatCard({ label, value, tone = 'default', icon }) {
  return (
    <div className={`stat-card stat-card--${tone}`}>
      {icon && <div className="stat-card__icon">{icon}</div>}
      <div className="stat-card__value">{value}</div>
      <div className="stat-card__label">{label}</div>
    </div>
  );
}
