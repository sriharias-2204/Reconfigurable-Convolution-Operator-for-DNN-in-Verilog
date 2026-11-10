import torch
import torch.nn as nn
import torchvision.transforms as transforms
from torchvision.models import densenet121, DenseNet121_Weights
from datasets import load_dataset
from tqdm.auto import tqdm
import csv
from IPython.display import FileLink

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"Executing on: {device}")

transform = transforms.Compose([
    transforms.Resize(256),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])

def preprocess_batch(batch):
    batch['image'] = [transform(img.convert('RGB')) for img in batch['image']]
    return batch

print("Downloading Validation Set to Kaggle Disk...")
dataset = load_dataset(
    "parquet", 
    data_files="hf://datasets/imagenet-1k/data/validation-*.parquet", 
    split="train" 
)
dataset.set_transform(preprocess_batch)

dataloader = torch.utils.data.DataLoader(dataset, batch_size=128, num_workers=2)

criterion = nn.CrossEntropyLoss()

def evaluate_model(model, dataloader, dtype=torch.float32, desc="Evaluating"):
    model.eval()
    correct_top1 = 0
    correct_top5 = 0
    total_loss = 0.0
    total = 0

    with torch.no_grad():
        for batch in tqdm(dataloader, desc=desc):
            images = batch['image'].to(device, dtype=dtype)
            labels = batch['label'].to(device)
            
            outputs = model(images)
            
            loss = criterion(outputs, labels)
            total_loss += loss.item() * images.size(0)
            
            _, pred = outputs.topk(5, 1, True, True)
            pred = pred.t()
            correct = pred.eq(labels.view(1, -1).expand_as(pred))
            
            correct_top1 += correct[:1].reshape(-1).float().sum(0, keepdim=True).item()
            correct_top5 += correct[:5].reshape(-1).float().sum(0, keepdim=True).item()
            total += labels.size(0)
            
    avg_loss = total_loss / total
    top1_acc = (correct_top1 / total) * 100
    top5_acc = (correct_top5 / total) * 100
    
    return top1_acc, top5_acc, avg_loss

def apply_approximate_bf16_mask(model):
    for name, module in model.named_modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            w_bf16 = module.weight.data.bfloat16()
            w_int16 = w_bf16.view(torch.int16)
            module.weight.data = (w_int16 & 0xFFFE).view(torch.bfloat16)
            
            if module.bias is not None:
                b_bf16 = module.bias.data.bfloat16()
                b_int16 = b_bf16.view(torch.int16)
                module.bias.data = (b_int16 & 0xFFFE).view(torch.bfloat16)

def calculate_weight_metrics(model_baseline, model_approx):
    mse_loss = nn.MSELoss()
    total_mse = 0.0
    total_mred = 0.0
    layer_count = 0
    
    for (name_b, mod_b), (name_a, mod_a) in zip(model_baseline.named_modules(), model_approx.named_modules()):
        if isinstance(mod_b, (nn.Conv2d, nn.Linear)):
            w_b = mod_b.weight.data.float()
            w_a = mod_a.weight.data.float()
            
            total_mse += mse_loss(w_b, w_a).item()
            
            epsilon = 1e-8 
            mred = torch.mean(torch.abs(w_b - w_a) / (torch.abs(w_b) + epsilon)).item()
            total_mred += mred
            
            layer_count += 1
            
    if layer_count > 0:
        return (total_mse / layer_count), (total_mred / layer_count)
    return 0, 0

results = []

print("\n--- Running Baseline FP32 ---")
model_fp32 = densenet121(weights=DenseNet121_Weights.IMAGENET1K_V1).to(device)
t1_fp32, t5_fp32, loss_fp32 = evaluate_model(model_fp32, dataloader, dtype=torch.float32, desc="FP32 Eval")
results.append({
    "Precision": "FP32 Baseline", "Top-1 Acc": f"{t1_fp32:.2f}%", "Top-5 Acc": f"{t5_fp32:.2f}%", 
    "Val Loss": f"{loss_fp32:.4f}", "Weight MSE": "0.0", "Weight MRED": "0.0"
})

print("\n--- Running Standard BF16 ---")
model_bf16 = densenet121(weights=DenseNet121_Weights.IMAGENET1K_V1).to(device).bfloat16()
t1_bf16, t5_bf16, loss_bf16 = evaluate_model(model_bf16, dataloader, dtype=torch.bfloat16, desc="BF16 Eval")
mse_bf16, mred_bf16 = calculate_weight_metrics(model_fp32, model_bf16)
results.append({
    "Precision": "Accurate BF16", "Top-1 Acc": f"{t1_bf16:.2f}%", "Top-5 Acc": f"{t5_bf16:.2f}%", 
    "Val Loss": f"{loss_bf16:.4f}", "Weight MSE": f"{mse_bf16:.8e}", "Weight MRED": f"{mred_bf16:.8e}"
})

print("\n--- Running Approximate BF16 (Hardware Sim) ---")
model_approx = densenet121(weights=DenseNet121_Weights.IMAGENET1K_V1).to(device)
apply_approximate_bf16_mask(model_approx)
model_approx = model_approx.bfloat16()
t1_appx, t5_appx, loss_appx = evaluate_model(model_approx, dataloader, dtype=torch.bfloat16, desc="Approx BF16 Eval")
mse_appx, mred_appx = calculate_weight_metrics(model_fp32, model_approx)
results.append({
    "Precision": "Approximate BF16", "Top-1 Acc": f"{t1_appx:.2f}%", "Top-5 Acc": f"{t5_appx:.2f}%", 
    "Val Loss": f"{loss_appx:.4f}", "Weight MSE": f"{mse_appx:.8e}", "Weight MRED": f"{mred_appx:.8e}"
})

csv_file = "/kaggle/working/inference_results_advanced.csv"
keys = results[0].keys()

with open(csv_file, 'w', newline='') as f:
    dict_writer = csv.DictWriter(f, fieldnames=keys)
    dict_writer.writeheader()
    dict_writer.writerows(results)

print("\n FINAL REPORT ")
for r in results:
    print(f"{r['Precision']:<20} | Top-1: {r['Top-1 Acc']:<7} | Top-5: {r['Top-5 Acc']:<7} | Loss: {r['Val Loss']:<6} | MSE: {r['Weight MSE']:<12} | MRED: {r['Weight MRED']}")

print("\nDone! Click below to download your results:")
display(FileLink(r'inference_results_advanced.csv'))
