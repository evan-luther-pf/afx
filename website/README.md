# afx website

A dependency-free static site for afx.

## Preview

Open `index.html` directly in a browser, or serve this directory locally:

```sh
cd website
python3 -m http.server 8000
```

Then visit <http://localhost:8000/>.

## Structure

- `index.html` — the complete semantic HTML document with restrained inline CSS
- `README.md` — local preview and structure notes

There is no build step and no external JavaScript, font, image, or stylesheet dependency.
