require('dotenv').config();
const app = require('./app');
require('./jobs/scheduler');      // pornește joburile la fiecare minut

app.listen(process.env.PORT || 5000, () => console.log('API pe portul', process.env.PORT || 5000));