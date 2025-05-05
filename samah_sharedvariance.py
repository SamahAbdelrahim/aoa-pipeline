import pandas as pd
import matplotlib.pyplot as plt
from matplotlib_venn import venn3

# Simulated correlations based on general expectations from the user's dataset
# These are illustrative; real values would come from the actual data
correlations = {
    ("shape", "solid"): 0.7,
    ("shape", "count_noun"): 0.6,
    ("solid", "count_noun"): 0.65
}

# Venn diagram needs binary sets; we use sets of overlapping variance as a metaphor
# Assume overlap values are proportional to correlation^2 (shared variance)

# Set sizes (total variance explained)
total_variance = 1.0  # each predictor normalized
shape_var = 1.0
solid_var = 1.0
count_var = 1.0

# Approximate shared variance using squared correlations
shape_solid = correlations[("shape", "solid")]**2
shape_count = correlations[("shape", "count_noun")]**2
solid_count = correlations[("solid", "count_noun")]**2

# Build a venn3 plot
plt.figure(figsize=(8, 6))
venn3(subsets = (shape_var, solid_var, shape_solid, count_var, shape_count, solid_count, 0.3),
      set_labels = ('Shape', 'Solid', 'Count Noun'))
plt.title("Approximate Shared Variance Between Predictors")
plt.show()
