export default {
  async email(message, env, ctx) {
    // Define your destination target for security/admin alerts
    const securityInbox = "security@example.com";
    
    // Define the support contact for unavailable mailboxes
    const contactInbox = "email@example.com";

    // Set of approved administrative and security aliases
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
      // Clean up the recipient address to isolate the local part
      const recipient = message.to.toLowerCase().trim();
      const localPart = recipient.split("@")[0];

      // Route based on whether the local part matches an admin alias
      if (securityAliases.has(localPart)) {
        await message.forward(securityInbox);
      } else {
        // Construct the multi-language rejection message with line breaks
        const rejectMessage = 
          `Requested action not taken: mailbox unavailable. If you believe this is an error, please send a message to ${contactInbox}.\n` +
          `Ação solicitada não realizada: caixa postal indisponível. Se você acha que isso é um erro, por favor envie uma mensagem para ${contactInbox}.\n` +
          `Acción solicitada no realizada: buzón no disponible. Si cree que esto es un error, por favor envíe un mensaje a ${contactInbox}.`;

        // Reject all other mailboxes with the custom multi-language error
        message.setReject(rejectMessage);
      }
    } catch (error) {
      console.error(`Routing failed for message from ${message.from} to ${message.to}:`, error);
    }
  }
};
