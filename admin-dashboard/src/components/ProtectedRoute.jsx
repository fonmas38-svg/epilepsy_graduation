import { Navigate, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import Spinner from './Spinner.jsx';

// Guards a route: requires authentication, and optionally one of `roles`.
// While the initial /auth/me check is in flight we render a spinner so we don't
// flash the login page for an already-authenticated admin.
export default function ProtectedRoute({ children, roles }) {
  const { isAuthenticated, role, loading } = useAuth();
  const location = useLocation();

  if (loading) return <Spinner full />;
  if (!isAuthenticated) {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }
  if (roles && roles.length && !roles.includes(role)) {
    return <Navigate to="/" replace />;
  }
  return children;
}
