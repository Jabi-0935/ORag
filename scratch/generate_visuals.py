import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# Load existing data
df = pd.read_csv("high_profile_rag_eval.csv")

# 7. Visualizations (Premium Split View)
sns.set_theme(style="whitegrid", palette="muted")

# Chart 1: Generation Quality
plt.figure(figsize=(10, 6))
gen_metrics = ['faithfulness', 'answer_relevance']
colors = ['#4C72B0', '#55A868'] # Sleek Blue and Green
ax1 = df[gen_metrics].mean().plot(kind='bar', color=colors, edgecolor='white', linewidth=1.5)
plt.title("O-RAG: Generation Quality", fontsize=16, fontweight='bold', pad=20)
plt.ylabel("Average Score", fontsize=12)
plt.xticks(rotation=0, fontsize=11)
plt.ylim(0, 1.1)
for p in ax1.patches:
    ax1.annotate(f'{p.get_height():.2f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                ha='center', va='center', xytext=(0, 10), textcoords='offset points', fontsize=12, fontweight='bold')
plt.tight_layout()
plt.savefig("rag_generation_quality.png", dpi=300)
print("Generation visualization saved to rag_generation_quality.png")

# Chart 2: Retrieval Quality
plt.figure(figsize=(10, 6))
ret_metrics = ['context_precision']
colors = ['#C44E52'] # Sleek Red
ax2 = df[ret_metrics].mean().plot(kind='bar', color=colors, edgecolor='white', linewidth=1.5)
plt.title("O-RAG: Retrieval Quality", fontsize=16, fontweight='bold', pad=20)
plt.ylabel("Average Score", fontsize=12)
plt.xticks(rotation=0, fontsize=11)
plt.ylim(0, 1.1)
for p in ax2.patches:
    ax2.annotate(f'{p.get_height():.2f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                ha='center', va='center', xytext=(0, 10), textcoords='offset points', fontsize=12, fontweight='bold')
plt.tight_layout()
plt.savefig("rag_retrieval_quality.png", dpi=300)
print("Retrieval visualization saved to rag_retrieval_quality.png")
