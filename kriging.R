# packages
library(magick)
library(data.table)

# ---- Load image ----
# If `img` is a filepath:
img <- image_read("Desktop/Roland.jpg")

# Optional: standardize size (RISE typically resizes; pick a modest size to keep things fast)
target_w <- 72L; target_h <- 72L
img_std <- image_resize(img, paste0(target_w, "x", target_h, "!"))

# ---- Convert to array + pixels table ----
# to array in [0,1]
img_arr <- drop(as.numeric(image_data(img_std)))
H <- dim(img_arr)[1]; W <- dim(img_arr)[2]

# Build a data.table of pixel coordinates (you’ll use this later)
pixels_dt <- data.table(
  y = rep.int(1:H, times = W),
  x = rep(1:W, each = H)
)
# Optionally attach colors (not strictly needed for saliency)
pixels_dt[, `:=`(
  r = as.vector(img_arr[,,1]),
  g = as.vector(img_arr[,,2]),
  b = as.vector(img_arr[,,3])
)]


prompt <- 
  "I will show you a social media user's profile image.
Based SOLELY on this profile image, I will show you a number of demographic categories to which this user may belong to.
The categories are preceded by a title (e.g. 'AGE:' or 'SEX:' etc.) and a symbol (e.g. 'A1', 'A2' or 'E1' etc.).
Please select, for each title, the most likely category to which this user belongs to BASED SOLELY ON THE VISUAL CONTENT OF THE PROFILE IMAGE.
In your answer present, for each title, the selected symbol.
Write out in full the category associated with the selected symbol.
The chosen symbol / category must be the most likely to accurately represent this user.
You must only select one symbol / category per title.
A title, symbol and category cannot appear more than once in your answer.
For each selected symbol / category, please note the level of Speculation involved in this selection.
Present the Speculation level for each selection on a scale from 0 (not speculative at all, clear visual evidence in the profile image) to 100 (fully speculative, no visual information related to this title in the profile image).
Speculation levels should be a direct measure of the amount of useful visual information available in the profile image.
Speculation levels pertain only to the visual information available in the profile image and should not be affected by additional information available to you from any other source.
To ensure consistency, use the following guidelines to determine speculation levels:
0-20 (Low speculation): The profile image provides clear and direct visual information relevant to the title (e.g., explicit visual evidence of age, gender presentation, etc.)
21-40 (Moderate-low speculation): The profile image provides indirect but strong visual indicators relevant to the title.
41-60 (Moderate speculation): The profile image provides some visual hints or partial information relevant to the title.
61-80 (Moderate-high speculation): The profile image provides limited and weak visual indicators relevant to the title.
81-100 (High speculation): The profile image provides no or almost no visual information relevant to the title.
For each selected category, please explain at length what visual features of the profile image contributed to your choice and your speculation level.
Preserve a strictly structured answer to ease parsing of the text.
Format your output as follows (this is just an example):
title: AGE
explanation: ...
symbol: A1)
category: 18-25
speculation: 90
For every title, you must include exactly these 5 fields: title, explanation, symbol, category, speculation. Do not omit any of them.
Please keep the EXACT WORDING for the titles!
YOU MUST GIVE AN ANSWER FOR EVERY TITLE!"
# let's score the image 
scored_img <- 
send_prompt(
  prompt = prompt,
  image_path = 'Desktop/profile.jpeg',
  azure_model_name = 'Llama-4-Maverick-17B-128E-Instruct-FP8'
)

content <- scored_img$choices[[1]]$message$content


# Parse the "speculation: NN" for a specific title from your LLM content
extract_spec_for_title <- function(content, title) {
  # find the block that contains `title: <TITLE>`
  pat <- paste0("title:\\s*", gsub("([\\W])","\\\\\\1", title), "\\b")
  blocks <- unlist(strsplit(content, "\\n\\s*\\n"))
  hit <- grep(pat, blocks, ignore.case = FALSE)
  if (length(hit) == 0) return(NA_integer_)
  blk <- blocks[hit[1]]
  m <- regexpr("speculation:\\s*([0-9]{1,3})", blk, perl = TRUE)
  if (m < 0) return(NA_integer_)
  as.integer(sub("speculation:\\s*([0-9]{1,3}).*", "\\1", regmatches(blk, m)))
}


# circular shift stays the same
roll2D <- function(m, dx = 0L, dy = 0L) {
  H <- nrow(m); W <- ncol(m)
  row_idx <- ((1:H - dy - 1L) %% H) + 1L
  col_idx <- ((1:W - dx - 1L) %% W) + 1L
  m[row_idx, col_idx, drop = FALSE]
}

# robust: generate an HxW mask in [0,1] using RGB and taking the R channel (or grayscale)
make_rise_mask <- function(H, W, s = 7L, p_keep = 0.5, jitter = TRUE, grayscale = FALSE) {
  # 1) low-res binary grid
  gh <- ceiling(H / s) + 1L
  gw <- ceiling(W / s) + 1L
  low <- matrix(rbinom(gh * gw, size = 1, prob = p_keep), nrow = gh, ncol = gw)
  
  # 2) upscale to HxW with bilinear interpolation
  low_img <- magick::image_read(as.raster(low))
  up_img  <- magick::image_resize(low_img, paste0(W, "x", H, "!"))
  
  # 3) pull back as RGB and collapse to a single channel
  # image_data returns a raw array [3 x H x W] with channels r,g,b
  rgb_raw <- magick::image_data(up_img, channels = "rgb")
  # convert to numeric 0..1
  r <- as.numeric(rgb_raw[1,,]) / 255
  g <- as.numeric(rgb_raw[2,,]) / 255
  b <- as.numeric(rgb_raw[3,,]) / 255
  # shape to HxW (image_data already indexes as [channel, row, col])
  dim(r) <- c(H, W); dim(g) <- c(H, W); dim(b) <- c(H, W)
  
  mask <- if (grayscale) {
    # luminance mix
    0.299*r + 0.587*g + 0.114*b
  } else {
    r  # a single channel is sufficient for a mask
  }
  
  # 4) optional jitter via circular shift
  if (jitter) {
    dx <- sample.int(s, 1) - 1L
    dy <- sample.int(s, 1) - 1L
    mask <- roll2D(mask, dx = dx, dy = dy)
  }
  
  pmin(pmax(mask, 0), 1)
}

# safer apply_mask (unchanged, but re-listed for convenience)
apply_mask <- function(img_arr, mask, fill = c("mean","gray","black")) {
  fill <- match.arg(fill)
  H <- dim(img_arr)[1]; W <- dim(img_arr)[2]
  if (is.null(dim(mask))) mask <- matrix(mask, nrow = H, ncol = W)
  stopifnot(nrow(mask) == H, ncol(mask) == W)
  mask <- as.numeric(mask); dim(mask) <- c(H, W)
  
  if (fill == "mean") {
    fill_rgb <- colMeans(matrix(img_arr, nrow = H*W, ncol = 3))
  } else if (fill == "gray") {
    fill_rgb <- rep(0.5, 3)
  } else {
    fill_rgb <- rep(0.0, 3)
  }
  
  out <- array(0, dim = dim(img_arr))
  for (c in 1:3) {
    out[,,c] <- mask * img_arr[,,c] + (1 - mask) * fill_rgb[c]
  }
  out
}



set.seed(42)
K <- 10L                    # number of masks this round
s <- 7L                     # RISE grid stride (lower = finer masks)
p_keep <- 0.5               # pixel keep prob on the low-res grid

mask_list <- vector("list", K)
masked_imgs <- vector("list", K)

# Pick one attribute to map (you can loop over all later)
spec0 <- extract_spec_for_title(content,title_to_run)  # 0..100
spec0 <- spec0 / 100     # normalize to 0..1
info0 <- 1-spec0

y = c()
k <- 0
while (length(y) < K) {
  k <- k + 1
  mk <- make_rise_mask(H, W, s = s, p_keep = 0.5, jitter = TRUE)
  mask_list[[k]] <- mk
  masked_arr <- apply_mask(img_arr, mk, fill = "mean")
  masked_img <- arr_to_magick(masked_arr)
  
  # write to a temp file because your send_prompt() expects image_path
  tf <- tempfile(fileext = ".png")
  magick::image_write(masked_img, path = tf, format = "png")
  # call your existing LLM prompt (use same prompt text as your baseline)
  resp <- send_prompt(
    prompt = prompt,
    image_path = tf,
    azure_model_name = 'Llama-4-Maverick-17B-128E-Instruct-FP8'
  )
  content_k <- resp$choices[[1]]$message$content
  spec_k <- extract_spec_for_title(content_k, title_to_run) / 100  # 0..1
  

  
  if (is.na( 1-spec_k )){
    k <- k-1; next
    }else{
  y[k] <- 1-spec_k
    }
  
}

library(INLA)       # R-INLA (SPDE kriging)
library(Matrix)
library(data.table)

H <- dim(img_arr)[1]; W <- dim(img_arr)[2]

# pixel centers as coordinates (use a unit square)
xy <- data.table(
  x = rep(seq(0, 1, length.out = W), each = H),
  y = rep(seq(0, 1, length.out = H), times = W)
)

# Build a reasonably dense mesh over the image domain
mesh <- inla.mesh.2d(
  loc = as.matrix(xy),
  max.edge = c(0.02, 0.05),
  cutoff   = 0.005,
  boundary = inla.nonconvex.hull(as.matrix(xy), convex = 0.1) # positive, not negative
)

# SPDE (Matérn) prior; set PC priors (range0 ~ typical correlation length, sigma0 ~ marginal sd)
spde <- inla.spde2.pcmatern(
  mesh = mesh,
  alpha = 2,
  prior.range = c(0.15, 0.5),   # P(range < 0.15) = 0.5
  prior.sigma = c(0.5, 0.5)     # P(sigma > 0.5) = 0.5
)

# Projector from mesh nodes -> ALL pixel centers (P x n.spde)
A_pix <- inla.spde.make.A(mesh = mesh, loc = as.matrix(xy))
P <- nrow(A_pix)                 # P = H*W
n_spde <- spde$n.spde





# Build sparse W (K x P) whose row k contains normalized occlusion weights for mask k
W_i <- integer(0); W_j <- integer(0); W_x <- numeric(0)

mask_list.tmp <- mask_list
mask_list <- mask_list
for (k in 1:K) {
  # occlusion weights Ok = 1 - mask (use soft values)
  Ok <- 1 - as.numeric(mask_list[[k]])
  # normalize to average (skip if mask reveals everything)
  s <- sum(Ok)
  if (s == 0) next
  Ok <- Ok / s
  
  idx <- which(Ok != 0)
  W_i <- c(W_i, rep.int(k, length(idx)))
  W_j <- c(W_j, idx)
  W_x <- c(W_x, Ok[idx])
}
W.sparse <- sparseMatrix(i = W_i, j = W_j, x = W_x, dims = c(K, P))

# Observation projector: K x n_spde
A_obs <- W.sparse %*% A_pix

# Response
y_vec <- as.numeric(y)[1:K]

# Observation stack (linking latent field to y via A_obs)
stk_obs <- inla.stack(
  data = list(y = y_vec),
  A    = list(A_obs),
  effects = list(field = 1:n_spde),
  tag  = "obs"
)

# Prediction stack for ALL pixels
stk_pred <- inla.stack(
  data = list(y = NA),
  A    = list(A_pix),
  effects = list(field = 1:n_spde),
  tag  = "pred"
)

stk <- inla.stack(stk_obs, stk_pred)

# Gaussian likelihood with tiny nugget (tune as needed)
res <- inla(
  formula = y ~ 0 + f(field, model = spde),  # no intercept; mean absorbed by field
  data = inla.stack.data(stk),
  family = "gaussian",
  control.predictor = list(
    A = inla.stack.A(stk),
    compute = TRUE
  ),
  control.compute = list(dic = FALSE, waic = FALSE, cpo = FALSE),
  verbose = TRUE
)

# Extract posterior mean/SD at pixel locations (the "pred" block)
idx_pred <- inla.stack.index(stk, tag = "pred")$data
mu <- res$summary.fitted.values$mean[idx_pred]
sd <- res$summary.fitted.values$sd[idx_pred]

# Reshape to HxW maps
map_mean <- matrix(mu, nrow = H, ncol = W, byrow = FALSE)
map_sd   <- matrix(sd, nrow = H, ncol = W, byrow = FALSE)







# H,W already known
ps <- max(6, round(min(H, W) * 0.12))   # scale text to image size

dbg <- base_img |>
  image_annotate("(1,1)",
                 gravity = "northwest", location = "+2+2",
                 size = ps, color = "white",
                 box = "rgba(0,0,0,0.6)")

dbg <- dbg |>
  image_annotate("(H,1)",
                 gravity = "southwest", location = "+2+2",
                 size = ps, color = "white",
                 box = "rgba(0,0,0,0.6)")

dbg <- dbg |>
  image_annotate("(1,W)",
                 gravity = "northeast", location = "+2+2",
                 size = ps, color = "white",
                 box = "rgba(0,0,0,0.6)")

dbg <- dbg |>
  image_annotate("(H,W)",
                 gravity = "southeast", location = "+2+2",
                 size = ps, color = "white",
                 box = "rgba(0,0,0,0.6)")

print(dbg)




# map_mean is H x W with indices [row=i (top->bottom), col=j (left->right)]
H <- nrow(map_mean); W <- ncol(map_mean)

pal <- colorRampPalette(c("blue", "white", "red"))(256)

# Normalize on the ORIGINAL (no transpose!) field
rng <- range(map_mean); eps <- 1e-8
h_norm <- (map_mean - rng[1]) / (diff(rng) + eps)
h_norm <- pmin(pmax(h_norm, 0), 1)
idx <- floor(h_norm * 255) + 1L

# Color matrix in the SAME [row, col] shape
col_mat <- matrix(pal[idx], nrow = H, ncol = W, byrow = FALSE)

# as.raster() expects row 1 = top row.
# Because magick already treats row 1 as top, DON'T transpose.
# If your colormap looks upside-down, flip *once* vertically:
# heat_img <- image_read(as.raster(col_mat[H:1, ]))
# But first try WITHOUT any flip:
heat_img <- magick::image_read(as.raster(col_mat))

# Ensure base and heat have identical geometry
base_img <- magick::image_resize(img_std, paste0(W, "x", H, "!"))
heat_img <- magick::image_resize(heat_img, paste0(W, "x", H, "!"))

# Blend (opacity 40% overlay)
overlay <- magick::image_composite(base_img, heat_img, operator = "blend", compose_args = "40")
print(overlay)

