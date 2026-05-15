# You Might Not Need an Effect

`useEffect` is an **escape hatch** for synchronizing with systems outside React.
Code that runs because a component was *displayed* belongs in Effects;
everything else belongs in events. Before writing one, verify it is needed.

## Contents

- Deriving state — calculate during render
- Caching expensive computation
- Resetting state on prop change
- Adjusting state on prop change
- Event logic vs Effect logic
- Sharing logic between handlers
- Sending a POST from a user action
- Chained Effects
- Notifying parent components
- Passing data to a parent
- Data fetching
- When an Effect IS correct
- Cleanup and race conditions
- Non-reactive values in Effects
- Subscribing to an external store
- One-time initialization
- Dependency array discipline
- Decision checklist
- Rules

## Deriving State — Calculate During Render

```tsx
// BAD: redundant state + unnecessary Effect
const [fullName, setFullName] = useState('')
useEffect(() => {
  setFullName(firstName + ' ' + lastName)
}, [firstName, lastName])

// GOOD: calculate during render
const fullName = firstName + ' ' + lastName
```

## Caching Expensive Computation

```tsx
// BAD: useEffect for a derived value
const [visibleTodos, setVisibleTodos] = useState<Todo[]>([])
useEffect(() => {
  setVisibleTodos(getFilteredTodos(todos, filter))
}, [todos, filter])

// GOOD: derive it; memoize only if measured to be slow
const visibleTodos = getFilteredTodos(todos, filter)
```

The React Compiler auto-memoizes — only reach for `useMemo` on a *measured*
expensive computation it cannot cover.

## Resetting State on Prop Change

```tsx
// BAD: resetting state in an Effect
useEffect(() => {
  setComment('')
}, [userId])

// GOOD: a changed key remounts the subtree and resets all its state
<Profile userId={userId} key={userId} />
```

## Adjusting State on Prop Change

```tsx
// BAD: adjusting selection via an Effect
useEffect(() => {
  setSelection(null)
}, [items])

// GOOD: derive from existing state
const selection = items.find((item) => item.id === selectedId) ?? null
```

For the rare case where you must adjust state on a prop change, store the
previous prop and compare *during render* — set state during render, no Effect:

```tsx
const [prevItems, setPrevItems] = useState(items)
if (items !== prevItems) {
  setPrevItems(items)
  setSelectedId(null)
}
```

## Event Logic vs Effect Logic

```tsx
// BAD: event logic in an Effect — fires on every reason `product` changes
useEffect(() => {
  if (product.isInCart) {
    showNotification(`Added ${product.name} to cart!`)
  }
}, [product])

// GOOD: it happened because the user clicked — put it in the handler
const handleBuyClick = () => {
  addToCart(product)
  showNotification(`Added ${product.name} to cart!`)
}
```

## Sharing Logic Between Handlers

```tsx
// BAD: an Effect to "share" logic between two handlers
useEffect(() => {
  if (lastAction) logAnalytics(lastAction)
}, [lastAction])

// GOOD: extract a plain function, call it from each handler
const buy = () => { addToCart(product); logAnalytics('buy') }
const wishlist = () => { addToWishlist(product); logAnalytics('wishlist') }
```

## Sending a POST From a User Action

```tsx
// BAD: triggering a POST via state + Effect
const [jsonToSubmit, setJsonToSubmit] = useState<FormData | null>(null)
useEffect(() => {
  if (jsonToSubmit !== null) post('/api/register', jsonToSubmit)
}, [jsonToSubmit])

// GOOD: POST directly in the event handler
const handleSubmit = (e: React.FormEvent) => {
  e.preventDefault()
  post('/api/register', { firstName, lastName })
}
```

An analytics POST on *mount* (the component was displayed) is the exception —
that belongs in an Effect.

## Chained Effects

```tsx
// BAD: cascading Effects — each render triggers the next
useEffect(() => { setGoldCardCount((c) => c + 1) }, [card])
useEffect(() => { setRound((r) => r + 1) }, [goldCardCount])
useEffect(() => { setIsGameOver(true) }, [round])

// GOOD: derive what you can, compute the rest in one event handler
const isGameOver = round > 5

const handlePlaceCard = (nextCard: Card) => {
  setCard(nextCard)
  if (nextCard.gold) {
    if (goldCardCount < 3) {
      setGoldCardCount(goldCardCount + 1)
    } else {
      setGoldCardCount(0)
      setRound(round + 1)
    }
  }
}
```

## Notifying Parent Components

```tsx
// BAD: syncing the parent via an Effect — an extra render pass
useEffect(() => {
  onChange(isOn)
}, [isOn, onChange])

// GOOD: update local state and notify the parent in the same event
const updateToggle = (nextIsOn: boolean) => {
  setIsOn(nextIsOn)
  onChange(nextIsOn)
}
```

## Passing Data to a Parent

```tsx
// BAD: child fetches, then pushes the result up through an Effect
function Child({ onFetched }: { onFetched: (d: Data) => void }) {
  const data = useSomeData()
  useEffect(() => {
    if (data) onFetched(data)
  }, [onFetched, data])
}

// GOOD: the parent owns the fetch and passes data down
function Parent() {
  const data = useSomeData()
  return <Child data={data} />
}
```

Data flows down. When a parent needs a child's data, lift the fetch to the
parent — don't bounce it back up through an Effect.

## Data Fetching

Never fetch with a raw Effect. This codebase uses **TanStack Query** — use it.
The Effect version leaks race conditions, has no caching, and no retry.

```tsx
// BAD: manual fetch in an Effect
useEffect(() => {
  fetch(`/api/missions/${id}`)
    .then((r) => r.json())
    .then(setMission)
}, [id])

// GOOD: a query hook handles caching, races, retries, loading state
const { mission, isLoading } = useGetMission(missionId)
```

Where Suspense is set up, `use(promise)` reads a promise during render — also
no Effect.

## When an Effect IS Correct

Synchronizing with systems outside React:

- Browser APIs — intersection/resize observers, event listeners.
- Non-React widgets — map libraries, charts, editors.
- WebSocket / subscription lifecycle.
- Analytics on mount.

## Cleanup and Race Conditions

Cleanup is **mandatory** for subscriptions and listeners:

```tsx
useEffect(() => {
  const handler = () => setWidth(window.innerWidth)
  window.addEventListener('resize', handler)
  return () => window.removeEventListener('resize', handler)
}, [])
```

Guard async work against races with an `ignore` flag or `AbortController`:

```tsx
useEffect(() => {
  let ignore = false
  fetchSomething(id).then((result) => {
    if (!ignore) setData(result)
  })
  return () => { ignore = true }
}, [id])
```

## Non-Reactive Values in Effects

Sometimes an Effect genuinely IS needed but re-runs too often because it
*reads* a value it should not *react* to (current theme, latest callback).
Keep that value out of the deps by reading it from a ref you keep current.

```tsx
// BAD: theme in deps — reconnects the socket every time the theme changes
useEffect(() => {
  const conn = createConnection(roomId)
  conn.on('connected', () => showToast('Connected!', theme))
  conn.connect()
  return () => conn.disconnect()
}, [roomId, theme])

// GOOD: stash the latest theme in a ref; the Effect reacts only to roomId
const themeRef = useRef(theme)
useEffect(() => { themeRef.current = theme }) // refreshed after every render

useEffect(() => {
  const conn = createConnection(roomId)
  conn.on('connected', () => showToast('Connected!', themeRef.current))
  conn.connect()
  return () => conn.disconnect()
}, [roomId]) // theme deliberately excluded — read via ref
```

First ask whether the Effect is needed at all. Reach for the ref pattern only
for a genuine external-system Effect that over-fires on an incidental value.

## Subscribing to an External Store

Prefer the purpose-built hook over an Effect with a listener:

```tsx
const isOnline = useSyncExternalStore(
  subscribe,
  () => navigator.onLine,
  () => true, // server snapshot
)
```

## One-Time Initialization

Logic that runs once per app, not once per mount, lives behind a guard:

```tsx
let didInit = false

const App = () => {
  useEffect(() => {
    if (!didInit) {
      didInit = true
      loadDataFromLocalStorage()
      checkAuthToken()
    }
  }, [])
}
```

## Dependency Array Discipline

List every reactive value the Effect reads. Never silence the lint rule to
skip a re-run.

```tsx
// BAD: lying about deps — `roomId` is read but omitted, and the linter is muted
useEffect(() => {
  const conn = createConnection(roomId)
  conn.connect()
  return () => conn.disconnect()
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [])

// GOOD: list what the Effect actually reads
useEffect(() => {
  const conn = createConnection(roomId)
  conn.connect()
  return () => conn.disconnect()
}, [roomId])
```

If a dependency makes the Effect run too often, fix the *cause* — move the
value into the Effect, derive it, or read it from a ref. Never suppress the
linter.

## Decision Checklist

Before writing an Effect, ask:

1. Can this be **calculated during render**? → Derive it, no state needed.
2. Is it a **measured-expensive** calculation? → `useMemo`.
3. Should state **reset on a prop change**? → Use `key`.
4. Did this happen because of a **user interaction**? → Event handler.
5. Is logic **shared between handlers**? → A plain function.
6. Is this **fetching data**? → TanStack Query (or `use()` + Suspense).
7. Is this **subscribing to an external store**? → `useSyncExternalStore`.
8. Is this **synchronizing with an external system**? → Effect, with cleanup.

Only if answer 8 applies should you reach for an Effect.

## Rules

1. **Code that runs because a component was displayed → Effect; everything else → an event.**
2. **Derive during render** instead of mirroring props/state into an Effect.
3. **Reset state with `key`**, never with an Effect that calls a setter.
4. **Put user-action logic in event handlers**, not Effects.
5. **Never fetch data in a raw Effect** — use TanStack Query or `use()` + Suspense.
6. **Never chain Effects** — compute all next state in one event handler.
7. **Always clean up** subscriptions, listeners, and connections.
8. **Guard async Effects** with an `ignore` flag or `AbortController`.
9. **Keep non-reactive values out of deps with a ref** when a genuine external-system Effect over-fires on an incidental value.
10. **Never bounce a child's data up to a parent through an Effect** — lift the fetch to the parent.
11. **Use `useSyncExternalStore`** for external-store subscriptions.
12. **Keep dependency arrays honest** — list every reactive value the Effect reads; never silence the linter.
