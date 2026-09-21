[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$Top = 0,

    [ValidateRange(0, 100)]
    [decimal]$MinDiscountPercent = 0,

    [ValidateRange(0, 999999)]
    [decimal]$MinPrice = 0,

    [ValidateRange(0, 999999)]
    [decimal]$MaxPrice = 0,

    [string]$Category
)

$ErrorActionPreference = 'Stop'
$baseUrl = 'https://www.webhallen.com'
$page = 1
$allItems = [System.Collections.Generic.List[object]]::new()

$filters = @()
if ($MinPrice -gt 0 -or $MaxPrice -gt 0) {
    $priceMin = if ($MinPrice -gt 0) { $MinPrice } else { 39 }
    $priceMax = if ($MaxPrice -gt 0) { $MaxPrice } else { 56990 }
    $filters += "price-3-$priceMin~$priceMax"
}

do {
    $filterParam = if ($filters.Count -gt 0) { "&filters[0]=$($filters -join '&filters[0]=')" } else { '' }
    $uri = "$baseUrl/api/productdiscovery/campaigns?page=$page&touchpoint=DESKTOP&totalProductCountSet=true&sortBy=highestDiscountPercent$filterParam"
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Region = 'se' } -UserAgent 'PowerShell Webhallen discount reader'

    foreach ($product in @($response.products)) {
        if ($Category -and ([string]$product.categoryTree).IndexOf($Category, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        $current = [decimal]$product.price.price
        $regular = [decimal]$product.regularPrice.price

        if ($regular -le $current) {
            continue
        }

        $discount = [math]::Round((($regular - $current) / $regular) * 100, 2)
        $stock = $product.stock.web -gt 0 -or $product.stock.isTrue

        if ($discount -lt $MinDiscountPercent) {
            continue
        }

        $allItems.Add([pscustomobject]@{
            Name           = $product.name
            Category       = [string]$product.categoryTree
            CurrentPrice   = $current
            RegularPrice   = $regular
            DiscountAmount = [math]::Round($regular - $current, 2)
            DiscountPercent= $discount
            InStock        = $stock
            CampaignEnds   = $product.price.endAt
            Url            = "$baseUrl/se/product/$($product.id)"
        })
    }

    $page++
} while (@($response.products).Count -gt 0 -and ($Top -eq 0 -or $allItems.Count -lt $Top))

$items = $allItems | Sort-Object DiscountPercent -Descending
if ($Top -gt 0) {
    $items = $items | Select-Object -First $Top
}

$items
