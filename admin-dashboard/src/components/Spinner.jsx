export default function Spinner({ full = false, label = 'جارٍ التحميل…' }) {
  return (
    <div className={full ? 'spinner-wrap spinner-wrap--full' : 'spinner-wrap'}>
      <div className="spinner" aria-hidden="true" />
      <span className="spinner-label">{label}</span>
    </div>
  );
}
