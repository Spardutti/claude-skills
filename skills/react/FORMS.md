# Forms — React Hook Form + Zod

The default is **React Hook Form with `zodResolver`**, because shadcn's `<Form>`
*is* React Hook Form — `Form` is a re-export of RHF's `FormProvider`, and
`FormField` wraps its `Controller`. Choosing anything else means not using the
component library you already have.

RHF 7.87 is current; 8.0 is in beta. `@hookform/resolvers` 5.9 handles Zod 3 and
Zod 4 from the same import, detecting the schema at runtime — one resolver, either
major, no separate package.

## Contents

- [The Shape](#the-shape)
- [The Typing Trap: input vs output](#the-typing-trap-input-vs-output)
- [Never Hand-Roll Submission State](#never-hand-roll-submission-state)
- [Server Errors Belong on the Field](#server-errors-belong-on-the-field)
- [Zod 3 and Zod 4 Are Not the Same](#zod-3-and-zod-4-are-not-the-same)
- [When Actions Instead](#when-actions-instead)
- [Rules](#rules)

## The Shape

One schema. It types the form and validates it — there is no second source of
truth for what a valid value is.

```tsx
const ProfileSchema = z.object({
  username: z.string().min(2, { error: "At least 2 characters." }),  // Zod 4 param
});

export function ProfileForm() {
  const form = useForm({
    resolver: zodResolver(ProfileSchema),
    defaultValues: { username: "" },
  });

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-8">
        <FormField
          control={form.control}
          name="username"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Username</FormLabel>
              <FormControl><Input {...field} /></FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" disabled={form.formState.isSubmitting}>Save</Button>
      </form>
    </Form>
  );
}
```

`<FormMessage />` renders the field's error itself. Reading
`formState.errors.username?.message` next to it is the same error twice.

Always pass `defaultValues`. Without them a field starts `undefined`, React calls
it uncontrolled, and the first keystroke logs a controlled/uncontrolled warning.

## The Typing Trap: input vs output

The moment a schema transforms — `z.coerce.number()`, `.transform()`, a default —
the type before validation and the type after are different. `z.infer` is the
*output* type, so pinning the form to it makes every input claim to be a number
while the DOM hands you a string.

```tsx
const Schema = z.object({ age: z.coerce.number() });  // in: string, out: number

// BAD — one generic pins both sides to the output type
useForm<z.infer<typeof Schema>>({ resolver: zodResolver(Schema) });

// GOOD — three generics: input, context, output
useForm<z.input<typeof Schema>, unknown, z.output<typeof Schema>>({
  resolver: zodResolver(Schema),
});
```

With no transforms anywhere, plain `useForm({ resolver })` infers correctly and
needs no generics at all. Reach for the three-generic form when — and only when —
a transform exists.

## Never Hand-Roll Submission State

```tsx
// BAD — three pieces of state RHF already tracks, and they drift
const [isSubmitting, setIsSubmitting] = useState(false);
const [errors, setErrors] = useState<Record<string, string>>({});
const [submitted, setSubmitted] = useState(false);

// GOOD
const { isSubmitting, isDirty, isValid, errors } = form.formState;
```

`handleSubmit` holds `isSubmitting` true for the whole async submit, so a button
disabled on it cannot double-fire. A hand-rolled flag set after an `await` can.

Disable submit on `isSubmitting`, not on `!isValid` — a form that refuses to
submit until it is perfect gives no feedback about *why*.

## Server Errors Belong on the Field

A rejection from the server is a form error, not a toast beside the form.

```tsx
// BAD — the message is nowhere near the field that caused it
catch (err) { toast.error("Something went wrong"); }

// GOOD — put it where the user is looking
catch (err) {
  if (err.code === "USERNAME_TAKEN") {
    form.setError("username", { message: "That username is taken." });
    return;
  }
  form.setError("root", { message: "Could not save. Try again." });
}
```

`root` is for errors that belong to no field. Render it with
`form.formState.errors.root?.message`.

## Zod 3 and Zod 4 Are Not the Same

Zod 4 collapsed `message` / `invalid_type_error` / `required_error` / `errorMap`
into a single `error` param, and moved formatting to standalone helpers.

```ts
z.string().min(5, { message: "Too short." })   // Zod 3
z.string().min(5, { error: "Too short." })     // Zod 4

err.flatten()          // Zod 3
z.flattenError(err)    // Zod 4 — also treeifyError, prettifyError
```

Zod 3 code type-checks against Zod 4 and quietly produces nothing. Check the major
in `package.json` before copying a schema between projects — two repos here are on
different ones.

## When Actions Instead

`useActionState` with `<form action>` is the right call for a form with **one**
submit, **one** error, and no per-field feedback — a search box, a single-button
confirm, a newsletter input. It needs no dependency and the inputs stay
uncontrolled.

Everything else is RHF. Per-field errors, validation as you type, arrays,
dependent fields, anything wrapped in shadcn's `<Form>`.

**Never combine them on one form.** `handleSubmit` and `<form action>` both own
submission; wiring both means one silently wins.

## Rules

- Always use React Hook Form with `zodResolver` for any form with per-field validation — shadcn's `<Form>` is RHF, so this is not a preference.
- Always pass `defaultValues`, or the first keystroke flips the field from uncontrolled to controlled.
- Always use `useForm<z.input<S>, unknown, z.output<S>>` when the schema transforms or coerces; a single `z.infer` pins the input type to the output.
- Always read `formState.isSubmitting` — never a hand-rolled `isSubmitting`, which can double-fire across an `await`.
- Always disable submit on `isSubmitting`, never on `!isValid`.
- Always put a server rejection on the field with `setError`, or on `root` when it belongs to no field.
- Always match the Zod major: `{ error }` and `z.flattenError` for 4, `{ message }` and `.flatten()` for 3.
- Never render `errors.field?.message` beside `<FormMessage />` — it already renders it.
- Never mix `handleSubmit` and `<form action>` on the same form.
