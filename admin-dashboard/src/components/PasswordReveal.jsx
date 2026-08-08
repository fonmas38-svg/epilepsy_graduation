import { useState } from 'react';
import { useToast } from '../context/ToastContext.jsx';

// Shows a freshly generated one-time password with copy-to-clipboard. Rendered
// after the server creates an account / resets a password without an explicit
// one, so the admin/doctor can hand the credential to the account owner.
export default function PasswordReveal({ password }) {
  const [copied, setCopied] = useState(false);
  const toast = useToast();
  if (!password) return null;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(password);
      setCopied(true);
      toast.success('تم نسخ كلمة المرور');
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error('تعذّر النسخ — انسخها يدوياً');
    }
  };

  return (
    <div className="password-reveal">
      <div className="password-reveal__hint">
        كلمة المرور المؤقتة (تُعرض مرة واحدة فقط — سلّمها لصاحب الحساب):
      </div>
      <div className="password-reveal__row">
        <code className="password-reveal__value">{password}</code>
        <button className="btn btn--ghost btn--sm" onClick={copy}>
          {copied ? 'تم النسخ ✓' : 'نسخ'}
        </button>
      </div>
    </div>
  );
}
