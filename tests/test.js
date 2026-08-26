import 'dotenv/config'
import { Sandbox } from 'e2b'

async function main() {
  const templateID = process.argv[2] ?? 'base'
  let sandbox

  try {
    sandbox = await Sandbox.create(templateID, {
      domain: process.env.E2B_DOMAIN,
      apiKey: process.env.E2B_API_KEY,
      requestTimeoutMs: 180_000,
      timeoutMs: 300_000,
    })

    await sandbox.files.write('/hello.txt', 'Hello World')
    console.log(await sandbox.files.read('/hello.txt'))
  } finally {
    await sandbox?.kill()
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
