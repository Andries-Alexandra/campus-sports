const router = require('express').Router();
const sequelize = require('../db');
const auth = require('../middleware/auth');

router.post('/', auth, async (req, res, next) => {
  try {
    const { facilityId, bookingDate, startTime, endTime, seats, reminderEnabled, equipment } = req.body;

    const bookingId = await sequelize.transaction(async (t) => {
      const [[{ booking_id }]] = await sequelize.query(
        `SELECT create_booking(:u, :f,
           (CAST(:d AS date) + CAST(:s AS time)) AT TIME ZONE 'Europe/Bucharest',
           (CAST(:d AS date) + CAST(:e AS time)) AT TIME ZONE 'Europe/Bucharest',
           :seats, :rem) AS booking_id`,
        { transaction: t,
          replacements: { u: req.user.id, f: facilityId, d: bookingDate, s: startTime, e: endTime,
                          seats: seats ?? 1, rem: reminderEnabled ?? true } });

      for (const eq of equipment ?? []) {
        await sequelize.query(
          'INSERT INTO booking_equipment (booking_id, equipment_id, quantity) VALUES (:b, :e, :q)',
          { transaction: t, replacements: { b: booking_id, e: eq.equipmentId, q: eq.quantity } });
      }
      return booking_id;
    });

    const [[booking]] = await sequelize.query(
      'SELECT * FROM v_booking_details WHERE booking_id = :id', { replacements: { id: bookingId } });
    res.status(201).json(booking);   // fără QR: qr_payload e NULL până la plată
  } catch (e) { next(e); }
});

module.exports = router;