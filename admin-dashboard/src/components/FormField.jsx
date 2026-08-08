// Labeled input for forms. Supports text/password/select via `as`.
export default function FormField({
  label,
  name,
  value,
  onChange,
  type = 'text',
  as = 'input',
  options = [],
  placeholder = '',
  required = false,
  hint = '',
  autoFocus = false,
}) {
  return (
    <label className="field">
      <span className="field__label">
        {label}
        {required && <span className="field__req"> *</span>}
      </span>
      {as === 'select' ? (
        <select
          className="field__control"
          name={name}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        >
          {options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      ) : (
        <input
          className="field__control"
          name={name}
          type={type}
          value={value}
          placeholder={placeholder}
          required={required}
          autoFocus={autoFocus}
          onChange={(e) => onChange(e.target.value)}
        />
      )}
      {hint && <span className="field__hint">{hint}</span>}
    </label>
  );
}
