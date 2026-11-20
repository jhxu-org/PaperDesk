'use strict';
(() => {
    const content = document.getElementById('content');
    const send = (name, value) => window.webkit?.messageHandlers[name]?.postMessage(value);
    let height = 0, previousText = null, previousSources = null, previousVisuals = null, rendered = false;
    let images = new Map();
    function measure() {
        if (!rendered) return;
        const next = Math.ceil(content.getBoundingClientRect().height);
        if (next !== height) { height = next; send('chatHeight', height); }
    }
    window.PaperDeskChat = {
        update(payload) {
            document.documentElement.classList.toggle('dark', payload.dark);
            document.body.style.fontSize = payload.fontSize + 'px';
            const sources = JSON.stringify(payload.sources);
            const visuals = JSON.stringify(payload.visuals);
            if (payload.images) images = new Map(payload.images.map(image => [image.id, image.dataURL]));
            if (payload.text !== previousText || sources !== previousSources || visuals !== previousVisuals || payload.images) {
                const previews = (payload.visuals || []).map(visual => ({ ...visual, dataURL: images.get(visual.id) || '' }));
                content.innerHTML = PaperDeskMarkup.render(payload.text, payload.sources, previews);
                previousText = payload.text; previousSources = sources; previousVisuals = visuals;
            }
            rendered = true;
            measure(); document.fonts.ready.then(measure);
        }
    };
    new ResizeObserver(measure).observe(content);
    document.addEventListener('click', event => {
        const visual = event.target.closest('[data-visual]');
        if (visual) { event.preventDefault(); send('chatVisual', { id: visual.dataset.visual, action: visual.dataset.action }); return; }
        const link = event.target.closest('a');
        if (!link) return;
        event.preventDefault();
        if (link.classList.contains('citation')) {
            send('chatSource', decodeURIComponent(new URL(link.href).pathname.slice(1)));
        }
    });
    document.addEventListener('dragstart', event => event.preventDefault());
})();
