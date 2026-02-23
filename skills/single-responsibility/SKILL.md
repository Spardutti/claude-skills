---
name: single-responsibility
description: Enforce single responsibility, small files, low complexity, and decoupled code. Use when writing, reviewing, or refactoring any component, hook, service, or utility.
---

# Single Responsibility Principle

Every file, function, component, and hook does **one thing**. If you can describe it with "and", split it.

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

## Component Rules

### One Job Per Component

```tsx
// BAD: fetches, filters, renders list, AND handles item actions
const MissionDashboard = () => {
  const [missions, setMissions] = useState([])
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
  return <ul>{missions.map(m => <MissionCard key={m.id} mission={m} />)}</ul>
}
```

### Split Signal: When to Extract

Extract a new component when:
- A section of JSX has its own state or effects
- A block is conditionally rendered with its own logic
- A UI pattern repeats 2+ times
- A section could be described independently ("the filter bar", "the card header")

### Do NOT Over-Split

Keep together when:
- A form with its fields (splitting every input is noise)
- A table with its columns (natural unit)
- Tightly coupled markup under ~50 lines with no independent state

## Hook Rules

### One Concern Per Hook

```tsx
// BAD: hook does fetching AND local UI state AND mutations
const useMissionPage = (id: string) => {
  const [tab, setTab] = useState('overview')
  const query = useQuery(...)
  const mutation = useMutation(...)
  const handleDelete = () => { ... }
  return { tab, setTab, mission: query.data, handleDelete }
}

// GOOD: separate hooks for separate concerns
const useGetMission = (id: string) => {
  const query = useQuery({ ...queryKeys.missions.detail(id) })
  return { mission: query.data, isLoading: query.isLoading }
}

const useDeleteMission = () => {
  const queryClient = useQueryClient()
  const mutation = useMutation({ ... })
  return { deleteMission: mutation.mutateAsync, isDeleting: mutation.isPending }
}
```

### Hook Naming = Its Single Purpose

| Name | Purpose |
|------|---------|
| `useGetMission` | Fetch a mission |
| `useDeleteMission` | Delete mutation |
| `useMissionFilters` | Filter state logic |
| `useMapInteraction` | Map click/hover handlers |

If the name needs "And" → split it.

## Function Rules

### Pure, Small, Focused

```tsx
// BAD: does too much
const processLayerData = (layer: Layer) => {
  const validated = validateLayer(layer)
  const transformed = transformCoordinates(validated)
  const clustered = computeClusters(transformed)
  const formatted = formatForMap(clustered)
  return formatted
}

// GOOD: pipeline of single-purpose functions
const validateLayer = (layer: Layer): ValidatedLayer => { ... }
const transformCoordinates = (layer: ValidatedLayer): TransformedLayer => { ... }
const computeClusters = (layer: TransformedLayer): ClusteredLayer => { ... }
const formatForMap = (layer: ClusteredLayer): MapLayer => { ... }
```

### Early Returns Over Nesting

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

### One Export Focus Per File

```
features/missions/
  components/
    mission-card.tsx          # MissionCard only
    mission-list.tsx          # MissionList only
    mission-filters.tsx       # MissionFilters only
  hooks/
    use-get-missions.ts       # useGetMissions only
    use-delete-mission.ts     # useDeleteMission only
    use-mission-filters.ts    # useMissionFilters only
  schemas/
    mission-schema.ts         # mission zod schema only
  types.ts                    # mission types (shared across feature)
```

### Colocate Related Code, Separate Concerns

- Types shared across a feature → `types.ts`
- Types used in one file → define in that file
- Utility used once → inline it, don't create a utils file
- Utility used 2+ times within a feature → `features/{feature}/utils/`
- Utility used across features → `@/lib/`

## Service Rules

### One Resource Per Service

```tsx
// GOOD: focused service
class MissionService {
  getMission = async (id: string): Promise<Mission> => { ... }
  getMissions = async (params: MissionParams): Promise<PaginatedResponse<Mission>> => { ... }
  createMission = async (data: CreateMissionPayload): Promise<Mission> => { ... }
  deleteMission = async (id: string): Promise<void> => { ... }
}

export const missionService = new MissionService()
```

Never mix resources. `missionService` should not have `getAnalysis()`.

## State Rules

### Minimal State, Maximum Derivation

```tsx
// BAD: redundant state
const [items, setItems] = useState<Item[]>([])
const [count, setCount] = useState(0)        // derived from items
const [isEmpty, setIsEmpty] = useState(true)  // derived from items

// GOOD: derive everything possible
const [items, setItems] = useState<Item[]>([])
const count = items.length
const isEmpty = items.length === 0
```

### One Store Per Domain

```tsx
// BAD: god store
const useAppStore = create(() => ({
  user: null,
  missions: [],
  mapSettings: {},
  uiPreferences: {},
}))

// GOOD: focused stores
const useAuthStore = create(() => ({ user: null, setUser: ... }))
const useMapSettingsStore = create(() => ({ clustering: true, setClustering: ... }))
```

## Complexity Smell Test

Your code is too complex if:

1. You scroll to understand a single function
2. You need comments to explain control flow
3. A test requires 4+ mocks to set up
4. Changing one thing breaks unrelated behavior
5. You can describe the file with "and" (fetches data **and** formats it **and** renders the list)
6. A component has more than 3 useState calls → extract a custom hook
7. A file imports from more than 5 different feature directories → it knows too much

## Refactoring Checklist

When writing or reviewing code:

1. Can I describe this file/function in one short sentence without "and"?
2. Is the file under 200 lines?
3. Is every function under 30 lines?
4. Are there 3 or fewer levels of nesting?
5. Does each hook handle exactly one concern?
6. Is state minimal (no derived state stored)?
7. Could someone understand this file without scrolling?

If any answer is "no" → split, extract, or simplify before proceeding.
