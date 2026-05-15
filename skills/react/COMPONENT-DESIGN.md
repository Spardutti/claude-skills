# Component Design & Single Responsibility

Every file, component, hook, and function does **one thing**. If you can
describe it with "and", split it.

## Contents

- Hard limits
- One job per component
- Split signals — when to extract
- Don't over-split
- Custom hook extraction
- Hook naming
- Typing hooks
- Composition vs prop drilling vs Context
- Composition over boolean props
- Early returns over nesting
- File organization
- Server vs client boundaries
- Complexity smell test
- Refactoring checklist
- Rules

## Hard Limits

| Metric | Max | Action |
|--------|-----|--------|
| File length | 200 lines | Split into smaller modules |
| Function/hook body | 30 lines | Extract helpers or sub-hooks |
| Component JSX return | 50 lines | Extract child components |
| Function parameters | 3 | Use an options object |
| Component props | 5-6 | Compose smaller components or use children |
| Nesting depth (callbacks/conditionals) | 3 levels | Extract early returns or helpers |
| Cyclomatic complexity | 5 branches | Simplify or split logic |

## One Job Per Component

```tsx
// BAD: fetches, filters, renders list, AND handles item actions
const MissionDashboard = () => {
  const [missions, setMissions] = useState<Mission[]>([])
  const [filter, setFilter] = useState('')
  // ...fetch logic, filter logic, delete logic, 200+ lines of JSX
}

// GOOD: each piece has one job
const MissionDashboard = () => {
  return (
    <div>
      <MissionFilters />
      <MissionList />
    </div>
  )
}

const MissionList = () => {
  const { missions, isLoading } = useGetMissions()
  if (isLoading) return <MissionListSkeleton />
  return <ul>{missions.map((m) => <MissionCard key={m.id} mission={m} />)}</ul>
}
```

## Split Signals — When to Extract

Extract a new component when:

- A section of JSX has its own state or effects.
- A block is conditionally rendered with its own logic.
- A UI pattern repeats 2+ times.
- A section could be described independently ("the filter bar", "the card header").
- The JSX return passes 50 lines, or the file passes 200.

## Don't Over-Split

Keep together when:

- A form with its fields — splitting every `<input>` is noise.
- A table with its columns — a natural unit.
- Tightly coupled markup under ~50 lines with no independent state.

Over-splitting trades one large file for ten files that must be opened
together to understand one feature. Split on **independent concerns**, not on
line count alone.

## Custom Hook Extraction

Extract a hook when stateful logic is **reused**, or when it clutters a
component with a concern that has its own identity. One concern per hook.

```tsx
// BAD: hook does fetching AND local UI state AND mutations
const useMissionPage = (id: string) => {
  const [tab, setTab] = useState('overview')
  const query = useQuery(missionQuery(id))
  const mutation = useMutation(deleteMissionMutation())
  const handleDelete = () => mutation.mutate(id)
  return { tab, setTab, mission: query.data, handleDelete }
}

// GOOD: separate hooks for separate concerns
const useGetMission = (id: string) => {
  const query = useQuery(missionQuery(id))
  return { mission: query.data, isLoading: query.isLoading }
}

const useDeleteMission = () => {
  const mutation = useMutation(deleteMissionMutation())
  return { deleteMission: mutation.mutateAsync, isDeleting: mutation.isPending }
}
```

## Hook Naming

The hook name states its single purpose. "And" in the name → split it.

| Name | Purpose |
|------|---------|
| `useGetMission` | Fetch a mission |
| `useDeleteMission` | Delete mutation |
| `useMissionFilters` | Filter state logic |
| `useMapInteraction` | Map click/hover handlers |

## Typing Hooks

Inference covers most hooks. Annotate only where it can't.

```tsx
// useState: annotate when the initial value can't infer the real type
const [user, setUser] = useState<User | null>(null)   // null init
const [ids, setIds] = useState<string[]>([])          // empty array
const [count, setCount] = useState(0)                 // inferred — leave it

// useRef: nullable for DOM nodes, mutable for plain values
const inputRef = useRef<HTMLInputElement>(null)        // .current is read-only-ish
const timerRef = useRef<number | undefined>(undefined) // mutable instance value

// useReducer: type state + a discriminated-union action
type CounterAction =
  | { type: 'increment'; by: number }
  | { type: 'reset' }

function reducer(state: CounterState, action: CounterAction): CounterState {
  switch (action.type) {
    case 'increment': return { count: state.count + action.by }
    case 'reset':     return { count: 0 }
  }
}
```

Custom hooks: return a **tuple `as const`** for `useState`-like pairs, an
**object** for 3+ values so call sites name what they take.

```tsx
// tuple — order is the contract, like useState
function useToggle(initial = false) {
  const [on, setOn] = useState(initial)
  return [on, () => setOn((v) => !v)] as const   // without `as const`: (boolean | (() => void))[]
}

// object — named fields when there are several
function useMission(id: string) {
  const query = useQuery(missionQuery(id))
  return { mission: query.data, isLoading: query.isPending }
}
```

## Composition vs Prop Drilling vs Context

Reach for tools in this order — prefer the cheapest that works.

**Prop drilling 2-3 levels is fine.** Do not add Context to avoid it.

**Composition before Context.** Pass JSX through `children` or slot props so
intermediate components never see data they don't use.

```tsx
// BAD: drilling `user` through Layout just to reach Header
const Layout = ({ user }: { user: User }) => (
  <div><Header user={user} /><main>{/* ... */}</main></div>
)

// GOOD: compose — Layout never touches `user`
const Layout = ({ header, children }: {
  header: React.ReactNode
  children: React.ReactNode
}) => (
  <div>{header}<main>{children}</main></div>
)
// caller: <Layout header={<Header user={user} />}>...</Layout>
```

**Context only for genuinely global, rarely-changing values** — theme, auth,
locale, current user. In React 19, read it with `use()` (works inside
conditionals) and provide it with `<Context>` directly.

```tsx
const ThemeContext = createContext<Theme>('light')

const App = () => (
  <ThemeContext value={theme}>
    <Page />
  </ThemeContext>
)

const Toolbar = () => {
  const theme = use(ThemeContext) // no prop drilling, no <Context.Provider>
  return <div className={theme}>{/* ... */}</div>
}
```

A frequently-changing value in Context re-renders every consumer — that is a
state-management concern, not a Context use case.

**Typing a nullable Context.** When there is no sensible default, type the
context as `T | null`, default it to `null`, and assert in a custom hook so
consumers get a non-null type and a clear error if used outside the provider.

```tsx
const AuthContext = createContext<AuthState | null>(null)

function useAuth(): AuthState {
  const ctx = use(AuthContext)
  if (ctx === null) throw new Error('useAuth must be used within <AuthContext>')
  return ctx   // callers get AuthState, never AuthState | null
}
```

## Composition Over Boolean Props

When a component grows a pile of boolean/enum props to cover variants, that's
a split signal — compose instead.

```tsx
// BAD: prop explosion — every new variant adds a flag and an internal branch
<Modal hasHeader hasFooter isFullScreen showCloseButton
  title="Settings" footerText="Save" />

// GOOD: composition — the caller assembles only the parts it needs
<Modal>
  <Modal.Header>Settings</Modal.Header>
  <Modal.Body><SettingsForm /></Modal.Body>
  <Modal.Footer><Button>Save</Button></Modal.Footer>
</Modal>
```

### Compound Components

Attach related sub-components that share implicit state via Context while the
caller controls layout. Use this when the parts must coordinate (tabs,
accordions, menus, modals); use plain `children` / slot props when they don't.

```tsx
const ModalContext = createContext<{ close: () => void } | null>(null)

function Modal({ children, onClose }: {
  children: React.ReactNode
  onClose: () => void
}) {
  return <ModalContext value={{ close: onClose }}>{children}</ModalContext>
}

Modal.Header = function ModalHeader({ children }: { children: React.ReactNode }) {
  const ctx = use(ModalContext)
  return (
    <header className="flex justify-between border-b p-4">
      {children}
      <button onClick={ctx?.close}>×</button>
    </header>
  )
}
```

## Early Returns Over Nesting

```tsx
// BAD: deep nesting
const getStatus = (mission: Mission) => {
  if (mission.isActive) {
    if (mission.hasAnalysis) {
      if (mission.analysis.isComplete) {
        return 'complete'
      } else {
        return 'analyzing'
      }
    } else {
      return 'pending'
    }
  } else {
    return 'inactive'
  }
}

// GOOD: flat and scannable
const getStatus = (mission: Mission) => {
  if (!mission.isActive) return 'inactive'
  if (!mission.hasAnalysis) return 'pending'
  if (!mission.analysis.isComplete) return 'analyzing'
  return 'complete'
}
```

## File Organization

One export focus per file. Colocate related code, separate concerns.

```
features/missions/
  components/
    mission-card.tsx          # MissionCard only
    mission-list.tsx          # MissionList only
    mission-filters.tsx       # MissionFilters only
  hooks/
    use-get-missions.ts       # useGetMissions only
    use-delete-mission.ts     # useDeleteMission only
  schemas/
    mission-schema.ts         # mission zod schema only
  types.ts                    # mission types shared across the feature
```

- Types shared across a feature → `types.ts`. Types used in one file → define inline.
- Utility used once → inline it. Used 2+ times in a feature → `features/{feature}/utils/`.
- Utility used across features → `@/lib/`.

## Server vs Client Boundaries

In RSC frameworks (Next.js, etc.), keep `'use client'` boundaries small and at
the leaves. A client island should not pull a whole page client-side — wrap the
one interactive widget, not its parent layout.

```tsx
// BAD: 'use client' on the page — entire tree ships to the client
'use client'
const ProductPage = () => { /* static content + one button */ }

// GOOD: page stays a Server Component, only the button is a client island
const ProductPage = () => (
  <article>{/* static, server-rendered */}<AddToCartButton /></article>
)
// add-to-cart-button.tsx
'use client'
const AddToCartButton = () => { /* ... */ }
```

This is framework-dependent. A non-RSC SPA never uses these directives — N/A there.

## Complexity Smell Test

Your code is too complex if:

1. You scroll to understand a single function.
2. You need comments to explain control flow.
3. A test requires 4+ mocks to set up.
4. Changing one thing breaks unrelated behavior.
5. You can describe the file with "and".
6. A component has more than 3 `useState` calls → extract a custom hook.
7. A file imports from more than 5 feature directories → it knows too much.

## Refactoring Checklist

1. Can I describe this file/function in one sentence without "and"?
2. Is the file under 200 lines, every function under 30?
3. Are there 3 or fewer levels of nesting?
4. Does each hook handle exactly one concern?
5. Is state minimal — no derived state stored?
6. Could someone understand this file without scrolling?

## Rules

1. **Never exceed 200 lines per file** — split before you cross it.
2. **One job per component, one concern per hook** — "and" in the description means split.
3. **Functions ≤30 lines, JSX return ≤50 lines, ≤3 nesting levels.**
4. **Cap props at 5-6** — beyond that, compose with `children` or split.
5. **Compose, don't configure** — a growing set of boolean/enum variant props means switch to `children`, slots, or compound components.
6. **Prefer composition over Context** — pass JSX through `children`/slots before reaching for Context.
7. **Prop drilling 2-3 levels is fine** — do not add Context to avoid it.
8. **Context is for global, rarely-changing values only** — theme, auth, locale, user.
9. **Don't over-split** — keep forms with fields and tables with columns together.
10. **Use early returns** instead of nested conditionals.
11. **One export focus per file**; colocate by feature, name files for their single purpose.
12. **Keep `'use client'` boundaries at the leaves** in RSC frameworks.
13. **Three or more `useState` calls in one component** → extract a custom hook.
