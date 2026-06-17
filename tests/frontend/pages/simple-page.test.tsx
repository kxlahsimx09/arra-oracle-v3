import { describe, expect, test } from 'bun:test';
import App from '../../../frontend/src/App';
import { htmlFor, installBrowserLocation } from '../_render';

describe('Simple page', () => {
  test('renders simple mode without the dashboard shell', () => {
    const restore = installBrowserLocation('/simple');
    try {
      const html = htmlFor(<App />);
      expect(html).toContain('Simple mode');
      expect(html).toContain('Starting up…');
      expect(html).not.toContain('Control Surface');
      expect(html).not.toContain('Backend unavailable');
    } finally {
      restore();
    }
  });
});
