const express = require('express');
const app = express();
app.get('/', (req, res) => res.send('hello\n'));
app.listen(3000);
