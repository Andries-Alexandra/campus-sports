const cron = require('node-cron');
const sequelize = require('../db');

cron.schedule('* * * * *', async () => {
  try {
    await sequelize.query('SELECT expire_stale_bookings()');
    const [due] = await sequelize.query('SELECT * FROM claim_due_reminders()');
    for (const r of due) { /* Nodemailer: trimite emailul către r.email */ }
  } catch (e) { console.error('Job eșuat:', e.message); }
});