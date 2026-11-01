const express = require('express');
const { dbErrorHandler } = require('./middleware/errors');

const app = express();
app.use(express.json());
app.use('/api/v1/bookings', require('./routes/bookings'));
app.use(dbErrorHandler);          // ultimul, după toate rutele

module.exports = app;