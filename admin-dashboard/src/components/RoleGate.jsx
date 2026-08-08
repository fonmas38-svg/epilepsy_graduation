import { useAuth } from '../context/AuthContext.jsx';

// Renders children only when the current user's role is in `roles`.
// Used to hide admin-only controls inside pages a doctor can also open.
export default function RoleGate({ roles, children, fallback = null }) {
  const { role } = useAuth();
  if (!roles || roles.includes(role)) return children;
  return fallback;
}
