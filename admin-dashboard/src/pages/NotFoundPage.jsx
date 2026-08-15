import { Link } from 'react-router-dom';

export default function NotFoundPage() {
  return (
    <div className="notfound">
      <div style={{ fontSize: 54 }}>🧭</div>
      <h1 style={{ margin: 0 }}>الصفحة غير موجودة</h1>
      <p className="muted">تعذّر العثور على الصفحة المطلوبة.</p>
      <Link className="btn btn--primary" to="/">
        العودة للرئيسية
      </Link>
    </div>
  );
}
