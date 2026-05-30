export default {
  async email(message, env, ctx) {
    // Define your two destination targets
    const securityInbox = "security@example.com";
    const generalInbox = "mail+catch-all@example.com";

    // Set of administrative and security aliases
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
        await message.forward(generalInbox);
      }
    } catch (error) {
      console.error(`Routing failed for message from ${message.from} to ${message.to}:`, error);
    }
  }
};
