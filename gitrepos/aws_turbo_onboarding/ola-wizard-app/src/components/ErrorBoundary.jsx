import React from 'react';

// Catches a render error in any step so a bug shows a recoverable message instead of a blank page.
export default class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  componentDidCatch(error, info) {
    // eslint-disable-next-line no-console
    console.error('UI error:', error, info?.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="container">
        <div className="card" role="alert">
          <h2>Something went wrong</h2>
          <p className="lead">The page hit an unexpected error. Your saved configuration is not affected.</p>
          <div className="notice bad mono">{String(this.state.error?.message || this.state.error)}</div>
          <div className="nav">
            <button className="btn" onClick={() => this.setState({ error: null })}>Try again</button>
            <button className="btn primary" onClick={() => window.location.reload()}>Reload page</button>
          </div>
        </div>
      </div>
    );
  }
}
