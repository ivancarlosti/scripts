export default {
  // 1. WEB HANDLER (Handles browser visits to your .workers.dev link)
  async fetch(request, env, ctx) {
    const html = `
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Global Email Router</title>
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f3f4f6; color: #1f2937; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .container { background: white; padding: 2.5rem; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); text-align: center; max-width: 450px; width: 90%; }
            .icon { font-size: 3rem; margin-bottom: 1rem; }
            h1 { font-size: 1.5rem; margin-bottom: 0.5rem; color: #111827; }
            p { color: #6b7280; font-size: 0.95rem; line-height: 1.5; margin-bottom: 1.5rem; }
            .badge { display: inline-block; background-color: #d1fae5; color: #065f46; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.85rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="icon">📧</div>
            <h1>Global Email Router</h1>
            <p>This Cloudflare Worker handles background email routing and security filtering. There is nothing to see here via a web browser!</p>
            <span class="badge">System Operational</span>
        </div>
    </body>
    </html>
    `;

    return new Response(html, {
      headers: { "Content-Type": "text/html; charset=UTF-8" },
    });
  },

  // 2. EMAIL HANDLER (Handles incoming mail)
  async email(message, env, ctx) {
    const securityInbox = "security@example.com";
    const contactInbox = "email@example.com";

    const securityAliases = new Set([
      "abuse",
      "admin",
      "administrator",
      "hostmaster",
      "noc",
      "postmaster",
      "security",
      "webmaster"
    ]);

    try {
      const recipient = message.to.toLowerCase().trim();
      const localPart = recipient.split("@")[0];

      if (securityAliases.has(localPart)) {
        await message.forward(securityInbox);
      } else {
        const rejectMessage = 
          `[EN] Requested action not taken: mailbox unavailable. If you believe this is an error, please send a message to ${contactInbox}. [PT] Acao solicitada nao realizada: caixa postal indisponivel. Se voce acha que isso e um erro, por favor envie uma mensagem para ${contactInbox}. [ES] Accion solicitada no realizada: buzon no disponible. Si cree que esto es un error, por favor envie un mensaje a ${contactInbox}.`;

        message.setReject(rejectMessage);
      }
    } catch (error) {
      console.error(`Routing failed for message from ${message.from} to ${message.to}:`, error);
    }
  }
};
