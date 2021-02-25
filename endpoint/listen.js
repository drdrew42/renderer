const express = require('express')
const app = express()
const port = 80

app.get('/', (req, res) => {
    res.send('Hello World!')
})

app.post('/receive', (req, res) => {
    console.log(JSON.stringify(req.headers));
    res.send('Hello answerJWT!');
})

app.listen(port, () => {
    console.log(`Example app listening at http://localhost:${port}`)
})
