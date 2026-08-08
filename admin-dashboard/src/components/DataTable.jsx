import Spinner from './Spinner.jsx';

// Generic table. `columns` = [{ key, header, render?(row), width? }].
// Shows a loading spinner, an empty-state, and renders rows via render() or the
// raw field value.
export default function DataTable({ columns, rows, loading, empty = 'لا توجد بيانات', keyField = 'id' }) {
  if (loading) return <Spinner />;
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} style={c.width ? { width: c.width } : undefined}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {(!rows || rows.length === 0) && (
            <tr>
              <td className="table__empty" colSpan={columns.length}>
                {empty}
              </td>
            </tr>
          )}
          {rows &&
            rows.map((row) => (
              <tr key={row[keyField]}>
                {columns.map((c) => (
                  <td key={c.key}>{c.render ? c.render(row) : row[c.key] ?? '—'}</td>
                ))}
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  );
}
