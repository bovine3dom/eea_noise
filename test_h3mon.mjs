import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {createRequire} from 'node:module'
import {arrowColumnValues} from '../H3-MON/src/arrow-columns.js'

const require = createRequire(new URL('../H3-MON/package.json', import.meta.url))
const {tableFromIPC} = require('apache-arrow')
const {isValidCell, getResolution} = require('h3-js')
const file = process.argv[2] ?? 'data/h3/CY-r10-to-r8.arrow'
const resolution = Number(process.argv[3] ?? 8)
// H3-MON's Arrow reader rejects record-batch compression.
const table = tableFromIPC(readFileSync(file))
assert.deepEqual(table.schema.fields.map(field => field.name), ['index_upper', 'index_lower', 'value'])
const columns = Object.fromEntries(table.schema.fields.map(({name}) => {
    const column = table.getChild(name)
    assert.equal(column.nullCount, 0)
    return [name, arrowColumnValues(column, name)]
}))
assert(columns.index_upper instanceof Uint32Array)
assert(columns.index_lower instanceof Uint32Array)
assert(columns.value instanceof Float32Array)
assert(table.numRows > 0)
const indexes = new Set()
for (let i = 0; i < table.numRows; i++) {
    const index = ((BigInt(columns.index_upper[i]) << 32n) | BigInt(columns.index_lower[i])).toString(16)
    assert(isValidCell(index))
    assert.equal(getResolution(index), resolution)
    assert(Number.isFinite(columns.value[i]))
    assert(!indexes.has(index))
    indexes.add(index)
}
console.log(`${file}: ${table.numRows} uncompressed resolution-${resolution} rows; H3-MON Arrow loader passed`)
