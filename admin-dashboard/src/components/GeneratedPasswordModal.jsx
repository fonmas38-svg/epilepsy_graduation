import Modal from './Modal.jsx';
import PasswordReveal from './PasswordReveal.jsx';

// Shown after the server creates an account (or resets a password) WITHOUT an
// explicit password, so a one-time password was generated. It is displayed once
// here for the admin/doctor to hand over; the server only ever stored the hash.
export default function GeneratedPasswordModal({ password, title = 'كلمة المرور المؤقتة', onClose }) {
  if (!password) return null;
  return (
    <Modal
      title={title}
      onClose={onClose}
      footer={
        <button className="btn btn--primary" onClick={onClose}>
          تم
        </button>
      }
    >
      <p className="muted" style={{ marginTop: 0 }}>
        احفظ كلمة المرور التالية وسلّمها لصاحب الحساب — لن تُعرض مرة أخرى.
      </p>
      <PasswordReveal password={password} />
    </Modal>
  );
}
