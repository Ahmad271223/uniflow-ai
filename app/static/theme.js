// Farbschema vor dem ersten Zeichnen setzen (frueher inline; eigene Datei wegen der Content-Security-Policy)
try{const t=localStorage.getItem('theme')||'light';if(t!=='auto')document.documentElement.dataset.theme=t;}catch{document.documentElement.dataset.theme='light';}
