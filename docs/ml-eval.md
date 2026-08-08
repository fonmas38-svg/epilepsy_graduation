# ML Evaluation (MVP without hardware)
- Dataset: `epilepsy_signal_dataset.csv`
- Best algorithm: **logreg** (macro-F1=1.0000)
- Artifact: `backend/models/risk_model.joblib`

## Notes
- Labels include `watch` as pre-ictal/rising-risk (soft prediction) and `high_risk` as seizure-like activity.
- Replace dataset later with clinical recordings without changing the API.

## logreg (macro-F1=1.0000)

```
              precision    recall  f1-score   support

   high_risk      1.000     1.000     1.000       200
      stable      1.000     1.000     1.000       200
       watch      1.000     1.000     1.000       200

    accuracy                          1.000       600
   macro avg      1.000     1.000     1.000       600
weighted avg      1.000     1.000     1.000       600

```

Confusion:
```
[[200   0   0]
 [  0 200   0]
 [  0   0 200]]
```

## rf (macro-F1=1.0000)

```
              precision    recall  f1-score   support

   high_risk      1.000     1.000     1.000       200
      stable      1.000     1.000     1.000       200
       watch      1.000     1.000     1.000       200

    accuracy                          1.000       600
   macro avg      1.000     1.000     1.000       600
weighted avg      1.000     1.000     1.000       600

```

Confusion:
```
[[200   0   0]
 [  0 200   0]
 [  0   0 200]]
```

## gb (macro-F1=1.0000)

```
              precision    recall  f1-score   support

   high_risk      1.000     1.000     1.000       200
      stable      1.000     1.000     1.000       200
       watch      1.000     1.000     1.000       200

    accuracy                          1.000       600
   macro avg      1.000     1.000     1.000       600
weighted avg      1.000     1.000     1.000       600

```

Confusion:
```
[[200   0   0]
 [  0 200   0]
 [  0   0 200]]
```
