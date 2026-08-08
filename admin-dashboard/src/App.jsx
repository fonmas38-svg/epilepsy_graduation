import { Routes, Route, Navigate } from 'react-router-dom';
import ProtectedRoute from './components/ProtectedRoute.jsx';
import Layout from './components/Layout.jsx';
import { useAuth } from './context/AuthContext.jsx';
import LoginPage from './pages/LoginPage.jsx';
import OverviewPage from './pages/OverviewPage.jsx';
import DoctorsPage from './pages/DoctorsPage.jsx';
import PatientsPage from './pages/PatientsPage.jsx';
import AssignmentsPage from './pages/AssignmentsPage.jsx';
import UsersPage from './pages/UsersPage.jsx';
import AuditPage from './pages/AuditPage.jsx';
import MyPatientsPage from './pages/MyPatientsPage.jsx';
import NotFoundPage from './pages/NotFoundPage.jsx';

// The landing screen depends on role: admins get the system overview, doctors go
// straight to their patients. Kept as its own component so the "/" route never
// redirects to a screen it isn't allowed to see (which would loop).
function HomeRedirect() {
  const { role } = useAuth();
  if (role === 'admin') return <OverviewPage />;
  return <Navigate to="/my-patients" replace />;
}

// Route table. The admin owns the whole system; a doctor is redirected to their
// own patients view. RBAC is enforced twice: here (route guard) and again by the
// backend on every request — the UI never trusts the client alone.
export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />

      <Route
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route index element={<HomeRedirect />} />
        <Route
          path="doctors"
          element={
            <ProtectedRoute roles={['admin']}>
              <DoctorsPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="patients"
          element={
            <ProtectedRoute roles={['admin']}>
              <PatientsPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="assignments"
          element={
            <ProtectedRoute roles={['admin']}>
              <AssignmentsPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="users"
          element={
            <ProtectedRoute roles={['admin']}>
              <UsersPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="audit"
          element={
            <ProtectedRoute roles={['admin']}>
              <AuditPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="my-patients"
          element={
            <ProtectedRoute roles={['doctor', 'admin']}>
              <MyPatientsPage />
            </ProtectedRoute>
          }
        />
      </Route>

      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  );
}
