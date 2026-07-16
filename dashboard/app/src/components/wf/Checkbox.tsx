import { forwardRef, useEffect, useRef } from 'react'
import type { InputHTMLAttributes } from 'react'
import Box from '@mui/material/Box'
import { pv } from '../../utils/cssVars'

/* Watchfloor checkbox primitive — ui-primitives.md§Checkbox/Radio.

   - 14×14 sharp square (no border-radius)
   - Unchecked: wf.ink bg + wf.graphite border
   - Checked:   wf.signal bg + wf.ink 2px checkmark via ::after
   - Indeterminate: 8×1.5px signal bar centered (data-indeterminate
     selector targets the ::after pseudo)

   Wraps a real <input type="checkbox"> for native accessibility,
   keyboard handling, and form-element semantics. Visual chrome is
   appearance:none + sx pseudo-elements. */

export interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  indeterminate?: boolean
}

const Checkbox = forwardRef<HTMLInputElement, CheckboxProps>(function Checkbox(
  { indeterminate = false, ...rest },
  forwardedRef,
) {
  const innerRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    if (innerRef.current) innerRef.current.indeterminate = indeterminate
  }, [indeterminate])

  return (
    <Box
      component="input"
      type="checkbox"
      ref={(node: HTMLInputElement | null) => {
        innerRef.current = node
        if (typeof forwardedRef === 'function') forwardedRef(node)
        else if (forwardedRef) forwardedRef.current = node
      }}
      data-indeterminate={indeterminate ? 'true' : undefined}
      {...rest}
      sx={{
        appearance: 'none',
        WebkitAppearance: 'none',
        width: 14,
        height: 14,
        flexShrink: 0,
        margin: 0,
        padding: 0,
        position: 'relative',
        display: 'inline-block',
        verticalAlign: 'middle',
        bgcolor: 'wf.ink',
        border: '1px solid',
        borderColor: 'wf.graphite',
        borderRadius: 0,
        cursor: 'pointer',
        transition: 'background-color 120ms, border-color 120ms',
        '&:focus-visible': {
          outline: '1px solid',
          outlineColor: pv('wf-signal'),
          outlineOffset: 1,
        },
        '&:checked': {
          bgcolor: pv('wf-signal'),
          borderColor: pv('wf-signal'),
        },
        '&:checked::after': {
          content: '""',
          position: 'absolute',
          left: '4px',
          top: '0px',
          width: '3px',
          height: '7px',
          borderStyle: 'solid',
          borderColor: 'wf.ink',
          borderWidth: '0 2px 2px 0',
          transform: 'rotate(45deg)',
        },
        '&[data-indeterminate="true"]': {
          bgcolor: 'wf.ink',
          borderColor: pv('wf-signal'),
        },
        '&[data-indeterminate="true"]::after': {
          content: '""',
          position: 'absolute',
          left: '2px',
          top: '5.5px',
          width: '8px',
          height: '1.5px',
          bgcolor: pv('wf-signal'),
          transform: 'none',
          border: 'none',
        },
        '&:disabled': {
          opacity: 0.4,
          cursor: 'not-allowed',
        },
      }}
    />
  )
})

export default Checkbox
