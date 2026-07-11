// Unit tests for the Tragar AI ticket-sidebar app (app/scripts/app.js).
//
// The app wires init() to DOMContentLoaded: it reads the ticket via the
// Freshworks client, renders the "Ask Tragar AI" trigger, then on click lists
// attachments (showing a picker) or fires the answer webhook directly.

import { beforeEach, describe, expect, test, vi } from 'vitest';

// A fake Freshworks client. listAttachments returns the given attachments;
// answer resolves 202. Both are recorded for assertions.
function makeClient(attachments = []) {
  return {
    data: { get: vi.fn(async () => ({ ticket: { id: 55 } })) },
    request: {
      invokeTemplate: vi.fn(async (name) =>
        name === 'listAttachments'
          ? { response: JSON.stringify({ attachments }) }
          : { status: 202 }
      ),
    },
  };
}

// Boot the app fresh with the given client, fire DOMContentLoaded so init()
// runs, then flush its awaited promises.
async function boot(client) {
  global.app = { initialized: vi.fn(async () => client) };
  vi.resetModules();
  await import('../app/scripts/app.js');
  document.dispatchEvent(new Event('DOMContentLoaded'));
  await new Promise((resolve) => setTimeout(resolve, 0));
}

const invokedTemplates = (client) =>
  client.request.invokeTemplate.mock.calls.map((call) => call[0]);

describe('Tragar AI ticket-sidebar app', () => {
  beforeEach(() => {
    document.body.innerHTML = '<div id="root"></div>';
    vi.clearAllMocks();
  });

  test('renders the "Ask Tragar AI" trigger once the ticket loads', async () => {
    const client = makeClient();
    await boot(client);

    expect(client.data.get).toHaveBeenCalledWith('ticket');
    expect(document.querySelector('#ask')).not.toBeNull();
    expect(document.getElementById('root').textContent).toContain('Ask Tragar AI');
  });

  test('with no attachments, Ask fires the answer webhook directly', async () => {
    const client = makeClient([]);
    await boot(client);

    document.getElementById('ask').click();
    await new Promise((resolve) => setTimeout(resolve, 0));

    const names = invokedTemplates(client);
    expect(names).toContain('listAttachments');
    expect(names).toContain('answer');
  });

  test('with readable attachments, Ask shows the picker before answering', async () => {
    const client = makeClient([{ id: 12, name: 'loads.csv' }]);
    await boot(client);

    document.getElementById('ask').click();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(document.getElementById('root').textContent).toContain('Which attachments');
    expect(document.querySelector('input.att')).not.toBeNull();
    // The answer webhook must NOT fire until the agent chooses.
    expect(invokedTemplates(client)).not.toContain('answer');
  });
});
