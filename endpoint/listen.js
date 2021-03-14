import express from 'express';
import jwtVerify from 'jose/jwt/verify';
import parseJwk from 'jose/jwk/parse';
import generateSecret from 'jose/util/generate_secret';
import fromKeyLike from 'jose/jwk/from_key_like';

const app = express()
const port = 80;

app.get('/', (req, res) => {
    res.send('Hello World!')
})
app.get('/ping', (req, res) => {
    res.send('PONG')
})

//test endpoint for receiving answerJWT
app.post('/receive', async (req, res) => {
    console.log(JSON.stringify(req.headers.answerjwt));
    let secret = process.env.problemJWTsecret;
    secret = await parseJwk({kty: 'oct', k: Buffer.from(secret).toString('base64'), alg: 'HS256'});
    const {payload, protectedHeader} = await jwtVerify(req.headers.answerjwt, secret);
    console.log(JSON.stringify(payload, null, 2));
    res.send('Hello answerJWT!');
})

app.listen(port, () => {
    console.log(`Example app listening at http://localhost:${port}`)
})
