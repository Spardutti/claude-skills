---
name: drf-best-practices
category: Backend
description: "MUST USE when creating or editing Django REST Framework views, serializers, viewsets, or API configuration. Enforces thin serializers, service layer, queryset optimization, and object-level permissions."
---

# Django REST Framework Best Practices

Keep serializers thin, views declarative, business logic in services, and always optimize querysets.

## Architecture Rules

| Layer | Responsibility | Anti-Pattern |
|-------|---------------|--------------|
| Serializer | Validation + serialization only | Business logic in `.create()`/`.validate()` |
| View/ViewSet | HTTP concerns + orchestration | Fat views with inline queries and logic |
| Service | Business logic + state changes | Skipping services, putting logic in serializers |
| Model | Data integrity + simple properties | God models with 50+ methods |

## Serializer Rules

### Thin Serializers — Validation Only

```python
# BAD: business logic in serializer
class OrderSerializer(serializers.ModelSerializer):
    class Meta:
        model = Order
        fields = ["id", "user", "items", "total"]

    def create(self, validated_data):
        items_data = validated_data.pop("items")
        order = Order.objects.create(**validated_data)
        for item in items_data:
            if item["product"].stock < item["quantity"]:
                raise serializers.ValidationError("Out of stock")
            item["product"].stock -= item["quantity"]
            item["product"].save()
            OrderItem.objects.create(order=order, **item)
        send_confirmation_email(order)
        return order

# GOOD: serializer validates, service handles logic
class OrderCreateSerializer(serializers.Serializer):
    items = OrderItemSerializer(many=True)
    shipping_address = serializers.CharField(max_length=500)

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("At least one item required.")
        return value
```

### Separate Serializers for Read vs Write

```python
# BAD: one serializer doing everything
class ArticleSerializer(serializers.ModelSerializer):
    author = UserSerializer(read_only=True)
    author_id = serializers.IntegerField(write_only=True)
    class Meta:
        model = Article
        fields = "__all__"

# GOOD: dedicated serializers per operation
class ArticleListSerializer(serializers.ModelSerializer):
    author_name = serializers.CharField(source="author.get_full_name")
    class Meta:
        model = Article
        fields = ["id", "title", "author_name", "created_at"]

class ArticleDetailSerializer(serializers.ModelSerializer):
    author = UserSerializer(read_only=True)
    tags = TagSerializer(many=True, read_only=True)
    class Meta:
        model = Article
        fields = ["id", "title", "body", "author", "tags", "created_at"]

class ArticleCreateSerializer(serializers.Serializer):
    title = serializers.CharField(max_length=200)
    body = serializers.CharField()
    tag_ids = serializers.ListField(child=serializers.IntegerField())
```

### Never Use `fields = "__all__"` — explicitly list every field. `__all__` leaks new model fields silently.

## ViewSet Rules

### Action-Specific Serializers and Permissions

```python
class ArticleViewSet(viewsets.ModelViewSet):
    def get_serializer_class(self):
        if self.action == "list":
            return ArticleListSerializer
        if self.action == "retrieve":
            return ArticleDetailSerializer
        return ArticleCreateSerializer

    def get_permissions(self):
        if self.action in ["list", "retrieve"]:
            return [IsAuthenticated()]
        if self.action == "destroy":
            return [IsAdminUser()]
        return [IsAuthenticated(), IsProjectOwner()]

    def get_queryset(self):
        return Article.objects.select_related("author").prefetch_related("tags")

    def perform_create(self, serializer):
        article_service.create_article(
            data=serializer.validated_data,
            user=self.request.user,
        )
```

## Queryset Optimization

### Always Optimize Related Lookups

```python
# BAD: N+1 queries — each order triggers separate queries for user and items
def get_queryset(self):
    return Order.objects.all()

# GOOD: eager-load relationships
def get_queryset(self):
    return (
        Order.objects
        .select_related("user", "shipping_address")      # ForeignKey / OneToOne
        .prefetch_related("items", "items__product")      # ManyToMany / reverse FK
    )
```

### Use `defer()` for Large Fields and Filter in SQL

```python
# List view doesn't need the full body
def get_queryset(self):
    if self.action == "list":
        return Article.objects.defer("body").select_related("author")
    return Article.objects.select_related("author").prefetch_related("tags")

# BAD: filtering in Python
def get_queryset(self):
    return [o for o in Order.objects.all() if o.is_active]

# GOOD: filter in SQL
def get_queryset(self):
    return Order.objects.filter(is_active=True)
```

## Service Layer

### Keep Business Logic Out of Views and Serializers

```python
# services/order_service.py
from django.db import transaction

class OrderService:
    @transaction.atomic
    def create_order(self, data: dict, user) -> Order:
        order = Order.objects.create(user=user, shipping_address=data["shipping_address"])
        for item_data in data["items"]:
            product = Product.objects.select_for_update().get(id=item_data["product_id"])
            if product.stock < item_data["quantity"]:
                raise InsufficientStockError(product)
            product.stock -= item_data["quantity"]
            product.save(update_fields=["stock"])
            OrderItem.objects.create(order=order, **item_data)
        return order

order_service = OrderService()

# View calls service, not ORM directly
class OrderViewSet(mixins.CreateModelMixin, viewsets.GenericViewSet):
    serializer_class = OrderCreateSerializer
    permission_classes = [IsAuthenticated]

    def perform_create(self, serializer):
        order_service.create_order(
            data=serializer.validated_data,
            user=self.request.user,
        )
```

## Security

### Scope Querysets to the User

```python
# BAD: any authenticated user sees all orders (IDOR vulnerability)
class OrderViewSet(viewsets.ModelViewSet):
    queryset = Order.objects.all()

# GOOD: scope to current user
class OrderViewSet(viewsets.ModelViewSet):
    def get_queryset(self):
        return Order.objects.filter(user=self.request.user)
```

### Object-Level Permissions

```python
class IsOwner(permissions.BasePermission):
    def has_object_permission(self, request, view, obj):
        return obj.user == request.user
```

### Global Defaults in `settings.py`

```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.TokenAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 20,
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ],
    "DEFAULT_THROTTLE_RATES": {"anon": "100/hour", "user": "1000/hour"},
    "DEFAULT_FILTER_BACKENDS": [
        "django_filters.rest_framework.DjangoFilterBackend",
        "rest_framework.filters.SearchFilter",
        "rest_framework.filters.OrderingFilter",
    ],
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
}
```

## Validation

```python
class EventSerializer(serializers.Serializer):
    title = serializers.CharField(max_length=200)
    start = serializers.DateTimeField()
    end = serializers.DateTimeField()

    def validate_title(self, value):
        if Event.objects.filter(title__iexact=value).exists():
            raise serializers.ValidationError("Event with this title already exists.")
        return value

    def validate(self, data):
        if data["start"] >= data["end"]:
            raise serializers.ValidationError("End must be after start.")
        return data
```

Always validate API input through serializers — never trust `request.data` directly.

## Rules Summary

1. **Thin serializers** — validation and serialization only, no business logic
2. **Separate serializers** for list, detail, and create/update operations
3. **Never `fields = "__all__"`** — explicitly list every field
4. **Optimize every queryset** — `select_related`, `prefetch_related`, `defer`
5. **Service layer** for business logic — keep views and serializers declarative
6. **Scope querysets to user** — never expose unfiltered `.objects.all()`
7. **Object-level permissions** — implement `has_object_permission` for detail views
8. **Set global defaults** — authentication, permissions, throttling, pagination
9. **Use `transaction.atomic`** — wrap multi-step writes in services
10. **Filter in SQL** — never filter querysets in Python
